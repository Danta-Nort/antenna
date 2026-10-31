// SPDX-License-Identifier: AGPL-3.0-only
// "Stop agent and its processes" (CONTROL §33, experimental) on the fake daemon and a fake pseudo-terminal: the dock's
// menu item asks first (Cancel does nothing), then `agent_stop` sweeps the tab's terminal session and the tab says
// Stopped; an older daemon gets the window's own terminal stop and says so; every tab is registered with
// `agent_terminal` (the wrapper's PID) after its start and after a reconnect; Agents offers the same for an agent that
// runs; My devices asks the other computer with `device_agent_stop`, only where it can; the `agent` event `stopped`
// from another computer stops the tab and says where from; the notices say what was taken.

import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/agent_stop.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/agents/agent_stop_dialog.dart';
import 'package:antenna_desktop/ui/agents/agents_page.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/claude_screens.dart';
import '../support/fake_daemon.dart';
import '../support/fake_devices.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);
const _pw = 'correct horse battery';
const _me = 'helper';
final en = l10nFor('en');

Future<(AppModel, FakeDaemon, FakePty)> _running(WidgetTester t, {List<AgentInfo> more = const []}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..agentList = [const AgentInfo(name: _me, createdMs: 0, localLevel: 5, everyone: false), ...more];
  final c = FakeAgentComputer(hooks: true);
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
  expect(await m.startAgent(const AgentRunSpec(agent: _me, cli: AgentCli.claude, workDir: '/home/owner/shop'),
      auth: PasswordAuth(_pw)), isNull);
  final pty = c.last..emit(drawScreen(claudeBusy));
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
  await t.pump(const Duration(milliseconds: 300));
  return (m, d, pty);
}

Future<void> _openStop(WidgetTester t) async {
  await t.tap(find.byKey(const Key('code-menu')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('code-stop-all')));
  await t.pumpAndSettle();
}

String _status(WidgetTester t) => t.widget<Text>(find.byKey(const Key('code-status'))).data!;

void main() {
  testWidgets('a tab is registered with agent_terminal after its start and again after a reconnect', (t) async {
    final (m, d, pty) = await _running(t);
    expect(d.agentTerminals, [(_me, pty.pid)], reason: 'the wrapper: the pseudo-terminal\'s session leader');
    expect(m.runOf(_me)!.pid, pty.pid);
    await m.connect();
    expect(d.agentTerminals, [(_me, pty.pid), (_me, pty.pid)]);
    // An older daemon refuses it: nothing breaks, the next start still works.
    d.agentStopEnabled = false;
    await m.connect();
    expect(m.runOf(_me)!.alive, isTrue);
    m.disposeRuns();
  });

  testWidgets('the dock: the menu item asks first; Cancel does nothing', (t) async {
    final (m, d, pty) = await _running(t);
    await _openStop(t);
    expect(find.byKey(const Key('agent-stop-dialog')), findsOneWidget);
    expect(find.textContaining(en.agentStopTitle(_me), findRichText: true), findsOneWidget);
    expect(find.text(en.agentStopWhat), findsOneWidget);
    expect(find.text(en.agentStopMac), findsOneWidget);
    expect(find.text(en.agentStopApps), findsOneWidget);
    expect(find.byKey(const Key('experimental-agent-stop')), findsOneWidget);
    await t.tap(find.byKey(const Key('agent-stop-cancel')));
    await t.pumpAndSettle();
    expect(d.agentStops, isEmpty);
    expect(pty.signals, isEmpty);
    expect(m.runOf(_me)!.alive, isTrue);
    m.disposeRuns();
  });

  testWidgets('Stop: agent_stop sweeps the session, the tab says Stopped, the notice says what was taken', (t) async {
    final (m, d, pty) = await _running(t);
    // The daemon's sweep ends the terminal's process (SIGTERM to the session).
    d.onAgentStop = (_) => pty.end(-15);
    await _openStop(t);
    await t.tap(find.byKey(const Key('agent-stop-confirm')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(d.agentStops, [_me]);
    final run = m.runOf(_me)!;
    expect(run.alive, isFalse);
    expect(run.stoppedByOwner, isTrue);
    expect(_status(t), en.codeStateStopped, reason: 'Stopped, not "ended by signal 15"');
    expect(pty.signals, isEmpty, reason: 'nothing left for the window to stop');
    expect(find.text('${en.agentStoppedProcesses(_me, 4)} (claude, node, sleep)'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('what the daemon did not take of the tab\'s terminal, the window stops itself', (t) async {
    final (m, d, pty) = await _running(t);
    d.stopLeft = 1;
    await _openStop(t);
    await t.tap(find.byKey(const Key('agent-stop-confirm')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(pty.signals, [ProcessSignal.sighup]);
    expect(m.runOf(_me)!.alive, isFalse);
    expect(_status(t), en.codeStateStopped);
    expect(find.textContaining(en.agentStoppedLeft(1)), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('an older daemon (unknown_command): the window stops its own terminal and says only that', (t) async {
    final (m, d, pty) = await _running(t);
    d.agentStopEnabled = false;
    await _openStop(t);
    await t.tap(find.byKey(const Key('agent-stop-confirm')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(pty.signals, [ProcessSignal.sighup]);
    expect(m.runOf(_me)!.alive, isFalse);
    expect(_status(t), en.codeStateStopped);
    expect(find.text(en.agentStoppedTerminalOnly(_me)), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('the agent event "stopped" from another computer: the tab stops and says where from', (t) async {
    final (m, d, pty) = await _running(t);
    m.handleEvent(const AgentEvent(name: _me, change: 'stopped', by: 'Mac mini'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final run = m.runOf(_me)!;
    expect(run.alive, isFalse, reason: 'whatever is left of its terminal stops too');
    expect(run.stoppedFrom, 'Mac mini');
    expect(_status(t), en.codeStateStoppedFrom('Mac mini'));
    // Another agent's event: nothing.
    m.handleEvent(const AgentEvent(name: 'other', change: 'stopped', by: 'Mac mini'));
    m.handleEvent(const AgentEvent(name: _me, change: 'bound'));
    await t.pump();
    expect(_status(t), en.codeStateStoppedFrom('Mac mini'));
    expect(d.agentStops, isEmpty, reason: 'the window asked nothing itself');
  });

  testWidgets('Agents: the same action for an agent that runs (an AI app here), not for one that does not',
      (t) async {
    final (m, d, _) = await _running(t, more: [
      const AgentInfo(
          name: 'desktop', createdMs: 0, localLevel: 3, boundPid: 812, boundComm: 'Claude', boundAlive: true),
      const AgentInfo(name: 'sleeper', createdMs: 0, localLevel: 3),
    ]);
    d.stopHow = StopHow.app;
    d.stopProcesses = 0;
    d.stopNames = const [];
    await m.refreshAgents();
    expect(m.agentRunsNow('desktop'), isTrue);
    expect(m.agentRunsNow(_me), isTrue);
    expect(m.agentRunsNow('sleeper'), isFalse);
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 300));
    final scrollable = find.descendant(of: find.byType(AgentsPage), matching: find.byType(Scrollable)).first;
    await t.scrollUntilVisible(find.byKey(const Key('agent-row-sleeper')), 300, scrollable: scrollable);
    await t.pump();
    expect(find.byKey(const Key('agent-stop-sleeper')), findsNothing);
    await t.scrollUntilVisible(find.byKey(const Key('agent-stop-desktop')), -300, scrollable: scrollable);
    await t.pump();
    await t.tap(find.byKey(const Key('agent-stop-desktop')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('agent-stop-confirm')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(d.agentStops, ['desktop']);
    expect(find.text(en.agentStoppedApp('desktop')), findsOneWidget);
    m.disposeRuns();
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('the notices: not running, a sandbox with no process, a refusal', (t) async {
    final l = en;
    String text(String agent, String how, {int processes = 0}) => agentStopResultText(
        l,
        AgentStopResult(
            agent: agent, reply: AgentStoppedReply(agent: agent, how: how, processes: processes, left: 0)));
    expect(text('a', StopHow.none), l.agentStoppedNone('a'));
    expect(text('w', StopHow.worker), l.agentStopped('w'));
    expect(
        agentStopResultText(
            l,
            const AgentStopResult(
                agent: 'c',
                computer: 'Mac mini',
                reply: AgentStoppedReply(
                    agent: 'c',
                    contact: 'Mac mini',
                    how: StopHow.process,
                    processes: 2,
                    left: 0,
                    names: ['codex\x1b[2J', 'node']))),
        '${l.agentStoppedOn('c', 'Mac mini', 2)} (codex[2J, node)',
        reason: 'the names are plain text');
    final refused = agentStopResultText(
        l, const AgentStopResult(agent: 'a', error: XControlException(XErrorCode.notFound, 'no agent a')));
    expect(refused, startsWith('Could not stop a: '));
  });

  group('My devices', () {
    Future<(AppModel, FakeDaemon)> devices(WidgetTester t, {required bool stopAgents}) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
        ..devicesEnabled = true
        ..stopHow = StopHow.process
        ..stopProcesses = 2
        ..stopNames = const ['codex', 'node'];
      final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
      await m.connect();
      d.devicesState = demoDevices(stopAgents: stopAgents);
      await m.refreshDevices();
      t.view.physicalSize = const Size(1440, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(XApp(model: m));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const Key('nav-devices')));
      await t.pump(const Duration(milliseconds: 400));
      return (m, d);
    }

    testWidgets('the chip asks, then that computer stops its agent (device_agent_stop with contact and agent)',
        (t) async {
      final (_, d) = await devices(t, stopAgents: true);
      final chip = find.byKey(const Key('device-agent-stop-Mac mini-codex'));
      await t.scrollUntilVisible(chip, 200, scrollable: find.byType(Scrollable).first);
      await t.pump();
      await t.tap(chip);
      await t.pumpAndSettle();
      expect(find.textContaining(en.agentStopTitleOn('codex', 'Mac mini'), findRichText: true), findsOneWidget);
      await t.tap(find.byKey(const Key('agent-stop-confirm')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(d.deviceAgentStops, [('Mac mini', 'codex')]);
      expect(d.agentStops, isEmpty);
      expect(find.text('${en.agentStoppedOn('codex', 'Mac mini', 2)} (codex, node)'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('a computer whose Antenna cannot do it: the chip is off and says why', (t) async {
      final (_, d) = await devices(t, stopAgents: false);
      final chip = find.byKey(const Key('device-agent-stop-Mac mini-codex'));
      await t.scrollUntilVisible(chip, 200, scrollable: find.byType(Scrollable).first);
      await t.pump();
      expect(t.widget<InkWell>(chip).onTap, isNull);
      final tip = t.widget<Tooltip>(find.ancestor(of: chip, matching: find.byType(Tooltip)).first);
      expect(tip.message, contains(en.agentStopOlderDevice('Mac mini')));
      await t.tap(chip);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('agent-stop-dialog')), findsNothing);
      expect(d.deviceAgentStops, isEmpty);
    });
  });
}
