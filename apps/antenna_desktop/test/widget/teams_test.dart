// SPDX-License-Identifier: AGPL-3.0-only
// Teams of agents in the window (x-control/7, CONTROL §25, D-111; DESIGN "Teams") on the fake daemon: the section only
// for a daemon that has teams; the list and the board, its columns derived from the task states; New team (the form's
// checks, the password, what goes to the daemon); New task and Add worker; a review (Accept, Request changes, Answer a
// blocked worker, Apply to the team's branch, Cancel); the lead's request to apply to the project's branch, which only
// the owner's password applies (refused without it, pinned to the commit the owner saw); the capacity strip from
// `team_capacity` and derived without it; a worker's live output, only ever its own; the `team` event read again; and
// when an event wakes the team's lead.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/teams.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/code/start_agent_dialog.dart' show FolderChooser;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_devices.dart';
import '../support/fake_teams.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
const _pw = 'correct horse battery';

Future<(AppModel, FakeDaemon)> _model({int proto = 7, bool teams = true, void Function(FakeDaemon d)? setup}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..protoVersion = proto
    ..teamsEnabled = teams
    ..agentList = [const AgentInfo(name: 'claude', createdMs: 0, localLevel: 5)];
  d.addTeam(demoTeam());
  setup?.call(d);
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return (m, d);
}

Future<void> _pump(WidgetTester t, [int times = 2]) async {
  for (var i = 0; i < times; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _app(WidgetTester t, AppModel m, {Size size = const Size(1600, 1000)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await _pump(t);
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _pump(t);
}

Future<void> _board(WidgetTester t) async {
  await _tap(t, find.byKey(const Key('nav-teams')));
  await _tap(t, find.byKey(const Key('team-open-web')));
}

Finder _text(String s) => find.textContaining(s, findRichText: true);
Finder _in(Key k, Finder f) => find.descendant(of: find.byKey(k), matching: f);

String _id(int n) => demoTask(n, title: '').id;
String _short(int n) => _id(n).substring(0, 6);

/// The calls of [cmd] the window sent, with their fields.
List<Map<String, Object?>> _sent(FakeDaemon d, String cmd) => [for (final (c, f) in d.teamCalls) if (c == cmd) f];

class _Folder implements FolderChooser {
  @override
  Future<String?> pick(String confirm) async => '/Users/jordan/code/shop';
}

void main() {
  group('what an event means for a lead in a window terminal', () {
    final team = demoTeam();
    TeamEvent ev(String change, {String? state, String? by}) => TeamEvent(team: 'web', change: change, state: state, by: by);
    test('a worker submitting or asking, the daemon blocking or checking, the owner deciding: the lead wakes', () {
      expect(teamEventWakesLead(team, ev('task', state: TaskState.submitted, by: 'web.coder-1')), isTrue);
      expect(teamEventWakesLead(team, ev('task', state: TaskState.blocked, by: 'web.coder-3')), isTrue);
      expect(teamEventWakesLead(team, ev('task', state: TaskState.blocked, by: 'daemon')), isTrue, reason: 'limits');
      expect(teamEventWakesLead(team, ev('task', state: TaskState.submitted, by: 'daemon')), isTrue, reason: 'checked');
      expect(teamEventWakesLead(team, ev('task', state: TaskState.accepted, by: 'owner')), isTrue);
      expect(teamEventWakesLead(team, ev('task', state: TaskState.open, by: 'owner')), isTrue, reason: 'a new task');
      expect(teamEventWakesLead(team, ev('changed', by: 'owner')), isTrue, reason: 'the owner applied or changed rules');
      expect(teamEventWakesLead(team, ev('worker', state: WorkerState.idle, by: 'owner')), isTrue);
    });
    test('the lead\'s own changes, progress notes, the daemon\'s own returns and silent daemons: no line', () {
      expect(teamEventWakesLead(team, ev('task', state: TaskState.submitted, by: 'claude')), isFalse, reason: 'its own');
      expect(teamEventWakesLead(team, ev('task', state: TaskState.working, by: 'web.coder-1')), isFalse);
      expect(teamEventWakesLead(team, ev('task', state: TaskState.returned, by: 'daemon')), isFalse,
          reason: 'a failed check goes back to the worker by itself');
      expect(teamEventWakesLead(team, ev('task', state: TaskState.submitted)), isFalse,
          reason: 'a daemon that does not say who acted: could not check = no');
      expect(teamEventWakesLead(team, ev('worker', state: WorkerState.busy, by: 'daemon')), isFalse);
      expect(teamEventWakesLead(team, ev('apply_request', by: 'claude')), isFalse);
      expect(teamEventWakesLead(demoTeam(lead: null), ev('task', state: TaskState.submitted, by: 'web.coder-1')), isFalse,
          reason: 'the owner leads: nobody to wake');
    });
  });

  test('the board is a view of the task states', () {
    final b = boardOf(demoTeam());
    expect({for (final e in b.entries) e.key: e.value.length}, {
      BoardColumn.open: 2,
      BoardColumn.working: 1,
      BoardColumn.review: 1,
      BoardColumn.blocked: 1,
      BoardColumn.accepted: 1,
      BoardColumn.applied: 1,
      BoardColumn.cancelled: 0,
    });
    expect(BoardColumn.of(TaskState.returned), BoardColumn.working, reason: 'back with its worker');
    expect(BoardColumn.of(TaskState.assigned), BoardColumn.working);
    expect(BoardColumn.of('a state from a newer daemon'), BoardColumn.open);
    expect(validTeamName('web-2'), isTrue);
    for (final bad in ['', 'Web', 'web_2', 'a' * 25, 'web.x']) {
      expect(validTeamName(bad), isFalse, reason: bad);
    }
  });

  testWidgets('a v6 daemon, and a v7 daemon without teams: no Teams section, no team command', (t) async {
    for (final (proto, teams) in [(6, true), (7, false)]) {
      final (m, d) = await _model(proto: proto, teams: teams);
      await _app(t, m);
      expect(find.byKey(const Key('nav-teams')), findsNothing, reason: 'v$proto');
      expect(m.teamsSupported, isFalse);
      expect(m.teamsError, isNull, reason: 'a daemon without the feature is not an error');
      expect(d.calls.where((c) => c.startsWith('team_') || c.startsWith('task_')).length, proto < 7 ? 0 : 1,
          reason: 'asked once, not on every screen');
    }
  });

  testWidgets('the list: each team with its project, lead, workers, tasks and the lead\'s request', (t) async {
    final (m, _) = await _model();
    await _app(t, m);
    expect(_in(const Key('nav-teams'), find.text('1')), findsOneWidget, reason: 'the apply request waits for the owner');
    await _tap(t, find.byKey(const Key('nav-teams')));
    expect(find.text(en.teamsTitle), findsWidgets);
    expect(find.byKey(const Key('experimental-teams')), findsOneWidget);
    final card = find.byKey(const Key('team-card-web'));
    expect(_in(const Key('team-card-web'), find.text('/Users/jordan/code/web')), findsOneWidget);
    expect(_in(const Key('team-card-web'), _text(en.teamLedBy('claude'))), findsOneWidget);
    expect(_in(const Key('team-card-web'), _text(en.teamWorkersCount(4))), findsOneWidget);
    expect(_in(const Key('team-card-web'), _text('${en.teamColReview} 1')), findsOneWidget);
    expect(find.byKey(const Key('team-apply-waiting-web')), findsOneWidget);
    expect(card, findsOneWidget);
  });

  testWidgets('no teams: what a team is, and New team', (t) async {
    final (m, d) = await _model(setup: (d) => d.teamMap.clear());
    await _app(t, m);
    await _tap(t, find.byKey(const Key('nav-teams')));
    expect(find.byKey(const Key('teams-empty')), findsOneWidget);
    expect(find.text(en.teamsStep1Title), findsOneWidget);
    await _tap(t, find.byKey(const Key('team-new-empty')));
    expect(find.byKey(const Key('team-new-dialog')), findsOneWidget);
    expect(d.teamCalls.where((c) => c.$1 == 'team_create'), isEmpty);
  });

  testWidgets('the board: columns by state, each card with its assignee, note, check and change', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _board(t);
    for (final (col, task) in [
      ('open', 1),
      ('open', 2),
      ('working', 3),
      ('review', 4),
      ('blocked', 5),
      ('accepted', 6),
      ('applied', 7),
    ]) {
      expect(_in(Key('col-$col'), find.byKey(Key('task-card-${_short(task)}'))), findsOneWidget, reason: 'task $task in $col');
    }
    expect(find.byKey(const Key('col-cancelled')), findsNothing, reason: 'no cancelled task: no column');
    // The card of the submitted task: the worker's summary (from task_show), the check, the change.
    expect(find.byKey(Key('task-note-${_short(4)}')), findsOneWidget);
    expect(_text('An LRU of 256 entries'), findsOneWidget);
    expect(_in(Key('task-check-${_short(4)}'), _text(en.taskCheckOutcomePassed)), findsOneWidget);
    expect(_in(Key('task-card-${_short(4)}'), _text('+42 −8 · 3 files')), findsOneWidget);
    // The blocked task shows the question; the tainted one its ceiling.
    expect(_text('Which one is the source of truth?'), findsOneWidget);
    expect(_in(Key('task-card-${_short(2)}'), find.byKey(const Key('ceiling-2'))), findsOneWidget);
    expect(_in(Key('task-card-${_short(2)}'), _text(en.teamCeilingNoCommands(2))), findsOneWidget);
    // The summary from team_show carries no text; the full view was read for the cards' notes.
    expect(d.calls.where((c) => c == 'task_show'), isNotEmpty);
    // Facts of the team.
    expect(_text(en.teamRuleOwnerApplies('main')), findsOneWidget);
    expect(_text('antenna/web → main'), findsOneWidget);
  });

  testWidgets('capacity: the machine, the slots used and free, the models in memory, the work waiting', (t) async {
    final (m, _) = await _model();
    await _app(t, m);
    await _board(t);
    expect(_in(const Key('cap-machine'), _text(en.teamCapMachineFacts('bwrap', 4, 8))), findsOneWidget);
    expect(_in(const Key('cap-workers'), _text(en.teamCapWorkersOf(4, 4))), findsOneWidget);
    expect(_in(const Key('cap-slot-coder-claude'), _text(en.teamCapSlotUse(3, 3, 0))), findsOneWidget);
    expect(_in(const Key('cap-slot-docs-local'), _text(en.teamCapSlotUse(1, 1, 0))), findsOneWidget);
    expect(_in(const Key('cap-queued'), _text(en.teamCapQueuedValue(2, 0))), findsOneWidget);
    expect(_in(const Key('cap-models'), _text(en.teamCapModelsNone)), findsOneWidget);
  });

  testWidgets('capacity without team_capacity: derived from the budget, said so, no error', (t) async {
    final (m, d) = await _model(setup: (d) => d.teamCapacityEnabled = false);
    await _app(t, m);
    await _board(t);
    expect(m.teamCapacityAbsent, isTrue);
    expect(_in(const Key('cap-machine'), _text(en.teamCapThisComputer)), findsOneWidget);
    expect(_in(const Key('cap-slot-coder-claude'), _text(en.teamCapSlotUse(3, 3, 0))), findsOneWidget);
    expect(m.teamErrors, isEmpty);
    expect(d.calls.where((c) => c == 'team_capacity').length, 1, reason: 'not asked again');
  });

  testWidgets('New team: the form checks before the daemon, the password goes once, the board opens', (t) async {
    FolderChooser.instance = _Folder();
    final (m, d) = await _model(setup: (d) => d.teamMap.clear());
    await _app(t, m);
    await _tap(t, find.byKey(const Key('nav-teams')));
    await _tap(t, find.byKey(const Key('team-new')));
    // A bad name: refused in the form, nothing sent.
    await t.enterText(find.byKey(const Key('team-new-name')), 'Shop App');
    await _tap(t, find.byKey(const Key('team-new-create')));
    expect(find.text(en.teamNewBadName), findsOneWidget);
    expect(_sent(d, 'team_create'), isEmpty);
    await t.enterText(find.byKey(const Key('team-new-name')), 'shop');
    await _tap(t, find.byKey(const Key('team-new-create')));
    expect(find.text(en.teamNewBadProject), findsOneWidget);
    await _tap(t, find.byKey(const Key('team-new-choose')));
    expect(find.text('/Users/jordan/code/shop'), findsOneWidget);
    // The lead: claude is preselected; the check command and a registry.
    await t.enterText(find.byKey(const Key('team-new-check')), 'cargo test --offline');
    await _tap(t, find.byKey(const Key('team-new-check-add')));
    await t.enterText(find.byKey(const Key('team-new-host')), 'index.crates.io');
    await _tap(t, find.byKey(const Key('team-new-host-add')));
    await _tap(t, find.byKey(const Key('team-new-create')));
    // The password prompt; a wrong one first.
    await t.enterText(find.byKey(const Key('owner-password')), 'wrong');
    await _tap(t, find.byKey(const Key('password-ok')));
    expect(find.text(en.errWrongPassword), findsOneWidget);
    expect(m.teams, isEmpty);
    await _tap(t, find.byKey(const Key('team-new-create')));
    await t.enterText(find.byKey(const Key('owner-password')), _pw);
    await _tap(t, find.byKey(const Key('password-ok')));
    final sent = _sent(d, 'team_create').last;
    expect(sent['name'], 'shop');
    expect(sent['project'], '/Users/jordan/code/shop');
    expect(sent['lead'], 'claude');
    expect(sent['slots'], [
      {'role': 'coder', 'kind': 'claude', 'max': 2},
    ]);
    final tpl = sent['template']! as Map<String, Object?>;
    expect(tpl['checks'], [
      ['cargo', 'test', '--offline'],
    ]);
    expect(tpl['check_hosts'], ['index.crates.io']);
    expect(tpl['apply'], 'owner');
    expect(d.passwords['team_create'], _pw);
    expect(find.byKey(const Key('team-new-dialog')), findsNothing);
    expect(m.openTeam, 'shop', reason: 'the new team\'s board opens');
    expect(find.byKey(const Key('board-shop')), findsOneWidget);
  });

  testWidgets('own computers: whether each lends itself, as My devices reports it; the capacity strip lists the lenders',
      (t) async {
    final (m, d) = await _model(setup: (d) {
      d
        ..devicesEnabled = true
        ..devicesState = demoDevices()
        ..lendingMachines = const ['build server']
        ..contactList = [
          ...demoContacts(),
          contact('Mac mini', 61, trust: 5),
          contact('build server', 62, trust: 5),
          contact('studio', 63, trust: 5),
        ];
    });
    await _app(t, m);
    await _board(t);
    expect(_in(const Key('cap-other-machines'), find.text('build server')), findsOneWidget);
    await _tap(t, find.byKey(const Key('team-back')));
    await _tap(t, find.byKey(const Key('team-new')));
    await t.ensureVisible(find.byKey(const Key('team-new-machine-build server')));
    await t.pump();
    expect(_in(const Key('team-new-machine-build server'), find.text(en.teamNewLends)), findsOneWidget);
    expect(_in(const Key('team-new-machine-Mac mini'), find.text(en.teamNewNotLending)), findsOneWidget);
    expect(_in(const Key('team-new-machine-studio'), find.text(en.teamNewLendLater)), findsOneWidget,
        reason: 'no status from that computer yet');
    final s = t.widget<Switch>(find.descendant(of: find.byKey(const Key('team-new-machine-build server')), matching: find.byType(Switch)));
    expect((s.value, s.onChanged), (true, null), reason: 'shown as that computer reports it; changed only there');
  });

  testWidgets('New team, I lead it myself and local only: no lead goes to the daemon; a cloud line is refused', (t) async {
    FolderChooser.instance = _Folder();
    final (m, d) = await _model(setup: (d) => d.teamMap.clear());
    await _app(t, m);
    await _tap(t, find.byKey(const Key('nav-teams')));
    await _tap(t, find.byKey(const Key('team-new')));
    await t.enterText(find.byKey(const Key('team-new-name')), 'docs');
    await t.enterText(find.byKey(const Key('team-new-project')), '/Users/jordan/code/docs');
    await t.tap(find.text(en.teamNewLeadMe));
    await _pump(t);
    await _tap(t, find.byKey(const Key('team-new-local-only')));
    await _tap(t, find.byKey(const Key('team-new-create')));
    expect(find.text(en.teamNewLocalOnlySlots), findsOneWidget, reason: 'the Claude Code line in a local-only team');
    expect(_sent(d, 'team_create'), isEmpty);
    await _tap(t, find.byKey(const Key('team-new-local-only')));
    await _tap(t, find.byKey(const Key('team-new-create')));
    await t.enterText(find.byKey(const Key('owner-password')), _pw);
    await _tap(t, find.byKey(const Key('password-ok')));
    expect(_sent(d, 'team_create').last.containsKey('lead'), isFalse, reason: 'the owner leads');
  });

  testWidgets('review: Accept, then apply to the team\'s branch; Request changes sends the comment', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _board(t);
    await _tap(t, find.byKey(Key('task-open-${_short(4)}')));
    expect(find.byKey(Key('task-dialog-${_short(4)}')), findsOneWidget);
    expect(_text('Keep the 96 px thumbnails'), findsOneWidget, reason: 'the brief');
    expect(find.text(en.taskNextReviewLead('claude')), findsOneWidget);
    await _tap(t, find.byKey(const Key('task-accept')));
    expect(_sent(d, 'task_review').last, {'id': _id(4), 'verdict': 'accept'});
    expect(_in(const Key('task-state'), find.text(en.taskStateAccepted)), findsOneWidget);
    await _tap(t, find.byKey(const Key('task-apply')));
    expect(_sent(d, 'task_apply').last, {'id': _id(4)});
    expect(_in(const Key('task-state'), find.text(en.taskStateDone)), findsOneWidget);
    expect(d.teamApplied, isEmpty, reason: 'the project\'s branch is not touched by a task apply');
    await t.tapAt(const Offset(4, 4));
    await _pump(t);
    // Another submitted result: Request changes with a comment.
    d.addTeam(demoTeam());
    await m.refreshTeam('web');
    await _pump(t);
    await _tap(t, find.byKey(Key('task-open-${_short(4)}')));
    await _tap(t, find.byKey(const Key('task-changes')));
    await t.enterText(find.byKey(const Key('task-comment')), 'Evict on logout too.');
    await _tap(t, find.byKey(const Key('task-send-comment')));
    expect(_sent(d, 'task_review').last, {'id': _id(4), 'verdict': 'changes', 'comments': 'Evict on logout too.'});
    expect(_in(const Key('task-state'), find.text(en.taskStateReturned)), findsOneWidget);
  });

  testWidgets('a blocked task: the worker\'s question in the conversation, Answer sends it back with the answer', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _board(t);
    await _tap(t, find.byKey(Key('task-open-${_short(5)}')));
    expect(_in(Key('task-dialog-${_short(5)}'), _text('Which one is the source of truth?')), findsOneWidget);
    expect(_text(en.taskStepBlocked), findsOneWidget);
    expect(find.text(en.taskNextBlocked), findsOneWidget);
    await _tap(t, find.byKey(const Key('task-answer')));
    await t.enterText(find.byKey(const Key('task-comment')), 'users.theme is the source; drop settings_v1.');
    await _tap(t, find.byKey(const Key('task-send-comment')));
    expect(_sent(d, 'task_review').last,
        {'id': _id(5), 'verdict': 'changes', 'comments': 'users.theme is the source; drop settings_v1.'});
    expect(_in(const Key('task-state'), find.text(en.taskStateReturned)), findsOneWidget);
  });

  testWidgets('a task the daemon refuses: its words in the dialog, nothing changes', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _board(t);
    await _tap(t, find.byKey(Key('task-open-${_short(4)}')));
    d.teamError = const XControlException(XErrorCode.taskState, 'the task is cancelled: only a submitted result is accepted');
    await _tap(t, find.byKey(const Key('task-accept')));
    expect(_text(en.teamErrTaskState('the task is cancelled: only a submitted result is accepted')), findsOneWidget);
    expect(_in(const Key('task-state'), find.text(en.taskStateSubmitted)), findsOneWidget);
  });

  testWidgets('apply to the project\'s branch: the lead asks, only the owner\'s password applies, pinned to what was seen',
      (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _board(t);
    expect(find.byKey(const Key('team-apply-banner')), findsOneWidget);
    expect(_text(en.teamApplyAsks('claude', 'main')), findsOneWidget);
    // The window never applies by itself, whatever the subscription says.
    m.handleEvent(const TeamEvent(team: 'web', change: 'apply_request', by: 'claude'));
    await _pump(t);
    expect(d.calls.where((c) => c == 'team_apply'), isEmpty);
    await _tap(t, find.byKey(const Key('team-apply-review')));
    expect(find.byKey(const Key('team-apply-dialog')), findsOneWidget);
    expect(_text(en.teamApplyIncludes(1)), findsOneWidget);
    expect(_in(const Key('team-apply-dialog'), _text('Rename the config loader')), findsOneWidget);
    // No password: the daemon refuses, as it does for anyone without it; nothing is applied.
    await _tap(t, find.byKey(const Key('team-apply-ok')));
    expect(d.passwords['team_apply'], '');
    expect(find.text(en.errWrongPassword), findsOneWidget);
    expect(d.teamApplied, isEmpty);
    expect(find.byKey(const Key('team-apply-banner')), findsOneWidget);
    // The password: applied, pinned to the integration commit the dialog showed.
    await t.enterText(find.byKey(const Key('owner-password')), _pw);
    await _tap(t, find.byKey(const Key('team-apply-ok')));
    expect(d.teamApplied, [('web', '7d1e3a5c9b2f4e6a8c0d2b4f6a8e1c3d5f7b9a0e')]);
    expect(find.byKey(const Key('team-apply-done')), findsOneWidget);
    await _tap(t, find.byKey(const Key('team-apply-close')));
    expect(find.byKey(const Key('team-apply-banner')), findsNothing, reason: 'the request is answered');
  });

  testWidgets('apply when the team\'s branch moved since the owner looked: approval_mismatch, nothing applied', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _board(t);
    await _tap(t, find.byKey(const Key('team-apply')));
    d.teamError = const XControlException(XErrorCode.approvalMismatch, 'the integration branch moved since');
    await t.enterText(find.byKey(const Key('owner-password')), _pw);
    await _tap(t, find.byKey(const Key('team-apply-ok')));
    expect(find.text(en.teamErrApplyMoved), findsOneWidget);
    expect(d.teamApplied, isEmpty);
  });

  testWidgets('New task and Add worker: within the budget, no password', (t) async {
    final (m, d) = await _model(setup: (d) {
      final t0 = demoTeam(applyRequest: false);
      // A free coder slot and no free worker yet.
      d.addTeam(TeamInfo(
        name: t0.name,
        project: t0.project,
        target: t0.target,
        integration: t0.integration,
        lead: t0.lead,
        state: t0.state,
        slots: const [TeamSlot(role: 'coder', kind: WorkerKind.claude, max: 4)],
        maxWorkers: 4,
        template: t0.template,
        workers: t0.workers.take(1).toList(),
        tasks: t0.tasks,
      ));
    });
    await _app(t, m);
    await _board(t);
    await _tap(t, find.byKey(const Key('worker-add')));
    await _tap(t, find.byKey(const Key('worker-add-ok')));
    expect(_sent(d, 'team_add_worker').last, {'team': 'web', 'role': 'coder', 'kind': 'claude'});
    expect(d.passwords.containsKey('team_add_worker'), isFalse);
    expect(find.byKey(const Key('worker-web.coder-2')), findsOneWidget, reason: 'the new worker on the board');
    await _tap(t, find.byKey(const Key('task-new')));
    await t.enterText(find.byKey(const Key('task-new-title')), 'Add a health check endpoint');
    await t.enterText(find.byKey(const Key('task-new-brief')), 'GET /health answers 200 with the version.');
    await _tap(t, find.byKey(const Key('task-new-create')));
    final sent = _sent(d, 'task_new').last;
    expect(sent['title'], 'Add a health check endpoint');
    expect(sent['check'], ['cargo', 'test'], reason: 'the team\'s first check by default');
    expect(sent.containsKey('assignee'), isFalse, reason: 'left for the lead');
    expect(_text('Add a health check endpoint'), findsOneWidget);
  });

  testWidgets('a worker\'s live output: on its card, in its task, in its panel; never another worker\'s', (t) async {
    final (m, _) = await _model();
    await _app(t, m);
    await _board(t);
    final task3 = _id(3);
    m
      ..onWorkerOutput(WorkerOutputEvent(team: 'web', worker: 'web.coder-1', task: task3, turn: 7, part: 'start'))
      ..onWorkerOutput(WorkerOutputEvent(
          team: 'web', worker: 'web.coder-1', task: task3, turn: 7, part: 'text', text: 'Running the ISO week tests\n\x1b[31mok'))
      ..onWorkerOutput(WorkerOutputEvent(
          team: 'web', worker: 'web.coder-2', task: _id(4), turn: 5, part: 'text', text: 'SECRET of coder-2'));
    await _pump(t);
    expect(_in(Key('task-live-${_short(3)}'), _text('[31mok')), findsOneWidget);
    expect(_text('\x1b'), findsNothing, reason: 'plain text: the escape character never reaches the screen');
    await _tap(t, find.byKey(Key('task-open-${_short(3)}')));
    expect(find.byKey(const Key('live-web.coder-1')), findsOneWidget);
    expect(_in(const Key('live-web.coder-1'), _text('Running the ISO week tests')), findsOneWidget);
    expect(_in(const Key('live-web.coder-1'), _text('SECRET of coder-2')), findsNothing,
        reason: 'a worker\'s view shows only its own output');
    m.onWorkerOutput(WorkerOutputEvent(team: 'web', worker: 'web.coder-1', task: task3, turn: 7, part: 'activity', text: 'tool:Bash'));
    await _pump(t);
    expect(_in(const Key('live-web.coder-1'), _text(en.workerUsesTool('Bash'))), findsOneWidget);
    m.onWorkerOutput(WorkerOutputEvent(team: 'web', worker: 'web.coder-1', task: task3, turn: 7, part: 'end', text: 'done'));
    await _pump(t);
    expect(_in(const Key('live-web.coder-1'), _text(en.workerTurnEnded('done'))), findsOneWidget);
    await t.tapAt(const Offset(4, 4));
    await _pump(t);
    // The worker's panel: its own task only.
    await _tap(t, find.byKey(const Key('worker-web.coder-1')));
    expect(find.byKey(const Key('worker-panel-web.coder-1')), findsOneWidget);
    expect(_in(const Key('worker-panel-web.coder-1'), _text('Fix the date parser')), findsOneWidget);
    expect(_in(const Key('worker-panel-web.coder-1'), _text('Cache the avatar')), findsNothing,
        reason: 'another worker\'s task never shows in a worker\'s view');
    expect(_in(const Key('worker-panel-web.coder-1'), _text('SECRET of coder-2')), findsNothing);
    await _tap(t, find.byKey(const Key('worker-stop-web.coder-1')));
    expect(m.team('web')!.worker('web.coder-1')!.stopped, isTrue);
  });

  test('the watch: one per team with workers; its pieces reach the model; a lagged watch is opened again', () async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
      ..teamsEnabled = true
      ..agentList = [const AgentInfo(name: 'claude', createdMs: 0, localLevel: 5)];
    d.addTeam(demoTeam());
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, clock: () => fixedNow);
    addTearDown(m.dispose);
    await m.connect();
    await Future<void>.delayed(Duration.zero);
    final first = d.teamWatches('web');
    expect(first, hasLength(1));
    first.single.emit(WorkerOutputEvent(team: 'web', worker: 'web.coder-1', task: _id(3), turn: 2, part: 'snapshot',
        text: 'so far'));
    // A piece of another team on this connection is not this team's (the daemon sends none; the window checks).
    first.single.emit(const WorkerOutputEvent(team: 'other', worker: 'other.coder-1', turn: 1, part: 'text', text: 'x'));
    await Future<void>.delayed(Duration.zero);
    expect(m.workerLive['web.coder-1']!.text, 'so far');
    expect(m.workerLive.containsKey('other.coder-1'), isFalse);
    first.single.emit(const Lagged(40));
    await Future<void>.delayed(Duration.zero);
    expect(first.single.cancelled, isTrue);
    expect(d.teamWatches('web'), hasLength(1));
    expect(identical(d.teamWatches('web').single, first.single), isFalse, reason: 'a fresh watch, a fresh snapshot');
  });

  test('an action while a slow read of the board runs: the caller gets the board as it is after the action', () async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..teamsEnabled = true;
    final t0 = demoTeam(applyRequest: false);
    d.addTeam(TeamInfo(
      name: t0.name,
      project: t0.project,
      target: t0.target,
      integration: t0.integration,
      lead: t0.lead,
      state: t0.state,
      slots: const [TeamSlot(role: 'coder', kind: WorkerKind.claude, max: 4)],
      maxWorkers: 4,
      template: t0.template,
      workers: t0.workers.take(1).toList(),
    ));
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    addTearDown(m.dispose);
    await m.connect();
    d.teamShowDelay = const Duration(milliseconds: 200);
    // An event's read starts and sees one worker; the owner adds a second meanwhile.
    final slow = m.refreshTeam('web');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await m.addTeamWorker('web', 'coder'), isNull);
    expect(m.team('web')!.worker('web.coder-2'), isNotNull, reason: 'the action waited for a read after it');
    await slow;
  });

  testWidgets('a team event reads the board again; a removed team leaves the screen', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _board(t);
    final shows = d.calls.where((c) => c == 'team_show').length;
    // The worker submits from outside the window: the daemon's record changes, the event says so.
    final team = d.teamMap['web']!;
    d.addTeam(TeamInfo(
      name: team.name,
      project: team.project,
      target: team.target,
      integration: team.integration,
      lead: team.lead,
      state: team.state,
      slots: team.slots,
      maxWorkers: team.maxWorkers,
      template: team.template,
      workers: team.workers,
      tasks: [
        for (final x in team.tasks)
          x.id == _id(3)
              ? demoTask(3, title: x.title, assignee: x.assignee, state: TaskState.submitted, round: 1, minutes: 0)
              : x,
      ],
    ));
    m.handleEvent(TeamEvent(team: 'web', change: 'task', task: _id(3), state: TaskState.submitted, by: 'web.coder-1'));
    await _pump(t);
    expect(d.calls.where((c) => c == 'team_show').length, greaterThan(shows));
    expect(_in(const Key('col-review'), find.byKey(Key('task-card-${_short(3)}'))), findsOneWidget);
    d.teamMap.clear();
    m.handleEvent(const TeamEvent(team: 'web', change: 'removed', by: 'owner'));
    await _pump(t);
    expect(m.openTeam, isNull);
    expect(find.byKey(const Key('teams-empty')), findsOneWidget);
  });

  testWidgets('Stop all workers (no password), Make active again (password), Remove team', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await _board(t);
    await _tap(t, find.byKey(const Key('team-menu')));
    await _tap(t, find.byKey(const Key('team-stop')));
    await _tap(t, find.byKey(const Key('team-stop-ok')));
    expect(_sent(d, 'team_stop').last, {'team': 'web'});
    expect(m.team('web')!.active, isFalse);
    expect(find.byKey(const Key('task-new')).hitTestable(), findsOneWidget);
    await _tap(t, find.byKey(const Key('team-menu')));
    await _tap(t, find.byKey(const Key('team-activate')));
    await t.enterText(find.byKey(const Key('owner-password')), _pw);
    await _tap(t, find.byKey(const Key('password-ok')));
    expect(d.passwords['team_set'], _pw);
    expect(m.team('web')!.active, isTrue);
    await _tap(t, find.byKey(const Key('team-menu')));
    await _tap(t, find.byKey(const Key('team-remove')));
    await _tap(t, find.byKey(const Key('team-remove-ok')));
    expect(_sent(d, 'team_remove').last, {'team': 'web'});
    expect(find.byKey(const Key('teams-empty')), findsOneWidget);
  });

  testWidgets('the log: every step with its actor and decision, the workers\' texts not in it', (t) async {
    final (m, d) = await _model(setup: (d) {
      d.teamLogs['web'] = [
        TeamLogEntry(ts: demoTeamNow, actor: 'claude', action: 'worker_spawn', decision: 'done', detail: 'web.coder-1'),
        TeamLogEntry(ts: demoTeamNow, actor: 'daemon', action: 'run_check', task: _id(2), decision: 'denied',
            detail: 'tainted:level_2:no_commands_below_4'),
      ];
    });
    await _app(t, m);
    await _board(t);
    await _tap(t, find.byKey(const Key('team-menu')));
    await _tap(t, find.byKey(const Key('team-log')));
    expect(find.byKey(const Key('team-log-dialog')), findsOneWidget);
    expect(_text('worker_spawn'), findsOneWidget);
    expect(_text('tainted:level_2:no_commands_below_4'), findsOneWidget);
    expect(d.calls.where((c) => c == 'team_log'), hasLength(1));
  });
}
