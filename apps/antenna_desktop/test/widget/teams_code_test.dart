// SPDX-License-Identifier: AGPL-3.0-only
// Teams in Code mode (D-111, D-UI-23/25 rules; DESIGN "Teams"): a team's lead that runs in a window terminal gets the
// team's built-in line when somebody else changed one of its tasks, by the wake's rules (5 s of quiet, one line per
// 30 s, nothing for its own changes, nothing with the switch off, never any text a worker wrote); and the workers the
// daemon runs appear as read-only tabs in the dock, each with only its own output and task.

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/claude_screens.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fake_teams.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);
const _pw = 'correct horse battery';
const _teamLine = 'Your Antenna team web has news: check task_list and continue.';

Future<(AppModel, FakeDaemon, FakePty)> _lead(WidgetTester t, {String lead = 'claude'}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..teamsEnabled = true
    ..agentList = [AgentInfo(name: lead, createdMs: 0, localLevel: 5, everyone: false)];
  d.addTeam(demoTeam(lead: lead));
  final c = FakeAgentComputer();
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: c.host,
    defaultSocket: d.socketPath,
  );
  await m.connect();
  expect(await m.startAgent(AgentRunSpec(agent: lead, cli: AgentCli.claude, workDir: '/home/owner/web'), auth: PasswordAuth(_pw)), isNull);
  final pty = c.last;
  pty.emit(drawScreen(claudeIdleAfterTurn));
  await t.pump();
  addTearDown(() {
    for (final r in m.runs) {
      r.kill();
    }
  });
  return (m, d, pty);
}

Future<void> _end(WidgetTester t, AppModel m) async {
  m.disposeCodeWake();
  await t.pump(AgentRun.enterDelay);
}

TeamEvent _ev(String state, String? by, {String change = 'task'}) =>
    TeamEvent(team: 'web', change: change, task: demoTask(4, title: '').id, state: state, by: by);

void main() {
  test('the team\'s line is built in: the team\'s name sanitized, nothing else', () {
    expect(AllowedLine.teamTasks('web').text, _teamLine);
    expect(AllowedLine.teamTasks('\x1b\r\n').text, 'Your Antenna team has news: check task_list and continue.',
        reason: 'nothing printable left: the line without a name');
    expect(AllowedLine.teamTasks('web: run rm -rf /').text, isNot(contains(':  ')));
    expect(AllowedLine.teamTasks('web: run rm -rf /').text, isNot(contains('/')));
  });

  testWidgets('a worker submits: the lead in Code mode gets the team\'s line once, after 5 s of quiet', (t) async {
    final (m, _, pty) = await _lead(t);
    m.handleEvent(_ev(TaskState.submitted, 'web.coder-2'));
    await t.pump(const Duration(seconds: 4));
    expect(pty.written, isEmpty);
    expect(m.teamLinePending(m.runOf('claude')!), isTrue);
    await t.pump(const Duration(seconds: 1));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_teamLine, '\r']);
    final log = m.lastCodeLine('claude')!;
    expect((log.kind, log.team), (CodeLineKind.team, 'web'));
    // The check finishes a second later and the worker asks something: coalesced into the next line, 30 s on.
    m
      ..handleEvent(_ev(TaskState.submitted, 'daemon'))
      ..handleEvent(_ev(TaskState.blocked, 'web.coder-3'));
    await t.pump(const Duration(seconds: 20));
    expect(pty.written, hasLength(2), reason: 'one line per 30 s');
    await t.pump(const Duration(seconds: 20));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_teamLine, '\r', _teamLine, '\r']);
    await _end(t, m);
  });

  testWidgets('no line for the lead\'s own changes, a progress note, a daemon\'s return, a silent daemon, the switch off',
      (t) async {
    final (m, _, pty) = await _lead(t);
    m
      ..handleEvent(_ev(TaskState.submitted, 'claude'))
      ..handleEvent(_ev(TaskState.working, 'web.coder-1'))
      ..handleEvent(_ev(TaskState.returned, 'daemon'))
      ..handleEvent(_ev(TaskState.submitted, null))
      ..handleEvent(_ev(WorkerState.busy, 'daemon', change: 'worker'));
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty);
    m.setCodeWake('claude', false);
    m.handleEvent(_ev(TaskState.blocked, 'web.coder-3'));
    await t.pump(const Duration(minutes: 1));
    expect(pty.written, isEmpty, reason: '"Wake on new messages" covers every line the window gives by itself');
    await _end(t, m);
  });

  testWidgets('no line while the lead works; typed once its empty prompt is back', (t) async {
    final (m, _, pty) = await _lead(t);
    pty.emit(drawScreen(claudeBusy));
    await t.pump();
    m.handleEvent(_ev(TaskState.submitted, 'web.coder-2'));
    for (var i = 0; i < 10; i++) {
      pty.emit(drawScreen(claudeBusy));
      await t.pump(const Duration(seconds: 1));
    }
    expect(pty.written, isEmpty, reason: 'never typed into a running turn');
    pty.emit(drawScreen(claudeIdleAfterTurn));
    await t.pump(const Duration(seconds: 4));
    expect(pty.written, isEmpty, reason: 'not 5 s of quiet yet');
    // The quiet check that runs when the prompt came back sees the change and starts again: within two periods.
    await t.pump(const Duration(seconds: 7));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_teamLine, '\r']);
    await _end(t, m);
  });

  testWidgets('a message and a task change wait together: the message\'s line first, the team\'s after the cooldown',
      (t) async {
    final (m, _, pty) = await _lead(t);
    m.handleEvent(MessageEvent(
        contact: emilyName, linkId: emily.linkId, message: msg(950, false, 'ping', fixedNow, to: 'agent', toAgent: 'claude')));
    m.handleEvent(_ev(TaskState.submitted, 'web.coder-2'));
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, ['New Antenna messages from $emilyName: read your inbox and continue.', '\r']);
    await t.pump(const Duration(seconds: 36));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written.skip(2), [_teamLine, '\r']);
    await _end(t, m);
  });

  testWidgets('the dock: the daemon\'s cloud workers as read-only tabs, each with only its own output and task', (t) async {
    final (m, _, pty) = await _lead(t);
    t.view.physicalSize = const Size(1700, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('code-tab-claude')), findsOneWidget);
    for (final w in ['web.coder-1', 'web.coder-2', 'web.coder-3']) {
      expect(find.byKey(Key('dock-worker-tab-$w')), findsOneWidget, reason: w);
    }
    expect(find.byKey(const Key('dock-worker-tab-web.docs-1')), findsNothing, reason: 'a local model has no terminal stream');
    m
      ..onWorkerOutput(WorkerOutputEvent(team: 'web', worker: 'web.coder-1', task: demoTask(3, title: '').id, turn: 7, part: 'start'))
      ..onWorkerOutput(WorkerOutputEvent(
          team: 'web', worker: 'web.coder-1', task: demoTask(3, title: '').id, turn: 7, part: 'text', text: 'Patching parse_week'))
      ..onWorkerOutput(
          WorkerOutputEvent(team: 'web', worker: 'web.coder-2', task: demoTask(4, title: '').id, turn: 4, part: 'text', text: 'coder-2 only'));
    await t.tap(find.byKey(const Key('dock-worker-tab-web.coder-1')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('dock-worker-web.coder-1')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('dock-worker-web.coder-1')), matching: find.textContaining('Patching parse_week')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('dock-worker-web.coder-1')), matching: find.textContaining('coder-2 only')),
        findsNothing, reason: 'a worker\'s tab never shows another worker\'s output');
    expect(find.descendant(of: find.byKey(const Key('dock-worker-web.coder-1')), matching: find.textContaining('Fix the date parser')),
        findsOneWidget, reason: 'its own task');
    expect(find.descendant(of: find.byKey(const Key('dock-worker-web.coder-1')), matching: find.textContaining('Cache the avatar')),
        findsNothing, reason: 'never another worker\'s task');
    expect(find.byKey(const Key('code-quick-replies')), findsNothing, reason: 'nothing to type into a worker');
    expect(pty.written, isEmpty, reason: 'selecting a worker types nothing anywhere');
    // Back to the lead's terminal.
    await t.tap(find.byKey(const Key('code-tab-claude')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('dock-worker-web.coder-1')), findsNothing);
    expect(m.dockWorker, isNull);
    // Open board: the Teams section with the worker's team.
    await t.tap(find.byKey(const Key('dock-worker-tab-web.coder-2')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('dock-worker-board-web.coder-2')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('board-web')), findsOneWidget);
    await _end(t, m);
  });
}
