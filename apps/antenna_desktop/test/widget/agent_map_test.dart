// SPDX-License-Identifier: AGPL-3.0-only
// The agent map in the window (x-control/7, CONTROL §30, D-UI-38, D-UI-47; experimental), on the fake daemon: Agents →
// Map shows the groups and the lines; drawing a line from a card's handle opens the connect dialog, which sends exactly
// the owner's choices (an own computer: tasks, peer_tasks and the password; a contact's agent: no choice for its side;
// a person: no agent; two agents of this computer: `local`); the result says what became of the other side; a line is
// selected with a click, its popover says what it means and disconnects it, as Delete or Backspace do, with no password
// and with the pending, done and failed states in the status strip; recent messages are a layer that is off by default
// and never disconnects; groups and cards move and the arrangement is kept in the window's settings file; the canvas
// pans and zooms; an own computer is on the left whatever else there is; an older daemon draws no connections and
// sends nothing; the agent's card in the list shows its counterpart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_map.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/theme/x_theme.dart';
import 'package:antenna_desktop/ui/agents/agent_map_layout.dart';
import 'package:antenna_desktop/ui/agents/agent_map_popover.dart' show MapStatusKind;
import 'package:antenna_desktop/ui/agents/agent_map_view.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connections.dart';
import '../support/fake_daemon.dart';
import '../support/fake_teams.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
const _pw = 'correct horse battery';

Future<(AppModel, FakeDaemon)> _setup({bool enabled = true, bool local = false, void Function(FakeDaemon d)? tweak}) async {
  final demo = mapDemo();
  final d = FakeDaemon(contacts: demo.contacts)
    ..devicesEnabled = true
    ..teamsEnabled = true
    ..connectionsEnabled = enabled
    ..agentList = demo.agents
    ..devicesState = demo.devices
    ..trafficPairs = demo.traffic;
  d.localRoutesEnabled = local;
  d.addTeam(TeamInfo(
    name: 'site',
    project: '/Users/maya/code/site',
    target: 'main',
    integration: 'antenna/site',
    lead: 'docs-bot',
    state: 'active',
    workers: [demoWorker('site.docs-1', team: 'site', kind: WorkerKind.local, state: WorkerState.busy)],
  ));
  tweak?.call(d);
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  await m.refreshAgentMap();
  return (m, d);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

Finder _key(String k) => find.byKey(Key(k));

Future<void> _open(WidgetTester t, AppModel m, {bool map = true, Appearance? look}) async {
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: look));
  await _settle(t);
  await t.tap(_key('agents-button'));
  await _settle(t);
  if (map) {
    await t.tap(_key('agents-view-map'));
    await _settle(t);
  }
}

AgentMapViewState _map(WidgetTester t) => t.state<AgentMapViewState>(find.byType(AgentMapView));

/// Draw a line with the mouse from a card's handle to another card.
Future<void> _draw(WidgetTester t, String from, String to) async {
  final side = _key('agent-map-handle-$from-r').evaluate().isNotEmpty ? 'r' : 'l';
  final a = t.getCenter(_key('agent-map-handle-$from-$side'));
  final b = t.getCenter(_key('agent-map-node-$to'));
  final g = await t.startGesture(a, kind: PointerDeviceKind.mouse);
  await g.moveBy(const Offset(24, 0));
  await t.pump();
  await g.moveTo(b);
  await t.pump();
  await g.up();
  await _settle(t);
}

/// Drag with the mouse from [from] by [by], in small steps.
Future<void> _drag(WidgetTester t, Offset from, Offset by) async {
  final g = await t.startGesture(from, kind: PointerDeviceKind.mouse);
  for (var i = 1; i <= 8; i++) {
    await g.moveTo(from + by * (i / 8));
    await t.pump();
  }
  await g.up();
  await _settle(t);
}

Future<void> _password(WidgetTester t) async {
  await t.enterText(_key('owner-password'), _pw);
  await t.pump();
}

Future<void> _connect(WidgetTester t) async {
  await t.tap(_key('agent-connect-ok'));
  await _settle(t);
}

String _line(MapEdgeKind k, String local, String other) => 'agent-map-line-${k.name}:$local>$other';

Finder _status(MapStatusKind kind) => _key('agent-map-status-${kind.name}');

String _statusText(WidgetTester t) => t.widget<Text>(_key('agent-map-status-title')).data!;
String? _statusDetail(WidgetTester t) =>
    _key('agent-map-status-detail').evaluate().isEmpty ? null : t.widget<Text>(_key('agent-map-status-detail')).data;


void main() {
  testWidgets('the map: groups, cards, the lines that are set, the legend; the view stays chosen', (t) async {
    final (m, d) = await _setup();
    await m.connectAgent(const AgentConnectRequest(
        name: 'reviewer', contact: 'Build server', agent: 'lead', peerTasks: true, password: _pw));
    await _open(t, m);
    expect(_key('experimental-agent-map'), findsOneWidget);
    expect(find.text(en.mapHint), findsOneWidget);
    expect(_key('agent-map-legend'), findsOneWidget);
    expect(find.text(en.mapLegendTraffic), findsNothing, reason: 'recent messages are a layer, off by default');
    for (final c in ['here', 'c/Mac mini', 'c/Build server', 'c/Bob', 'c/Emily Carter']) {
      expect(_key('agent-map-cluster-$c'), findsOneWidget, reason: c);
    }
    expect(find.text('Mayas-MacBook-Pro'), findsOneWidget);
    for (final n in ['here/volna', 'here/docs-bot', 'here/reviewer', 'here/helper', 'here/site.docs-1',
      'c/Mac mini/a/session-2', 'c/Mac mini/a/codex', 'c/Build server/a/lead', 'c/Bob/p', 'c/Bob/a/builder',
      'c/Emily Carter/p', 'c/Emily Carter/a/chatgpt']) {
      expect(_key('agent-map-node-$n'), findsOneWidget, reason: n);
    }
    expect(find.text('Local model'), findsOneWidget);
    expect(find.text(en.mapKindWorker('site')), findsOneWidget);
    // A line set both ways with tasks at both ends; one set from here; waiting on the build server; the team
    expect(_key(_line(MapEdgeKind.configured, 'here/volna', 'c/Mac mini/a/session-2')), findsOneWidget);
    expect(_key('agent-map-tasks-configured:here/volna>c/Mac mini/a/session-2-here'), findsOneWidget);
    expect(_key('agent-map-tasks-configured:here/volna>c/Mac mini/a/session-2-there'), findsOneWidget);
    expect(_key(_line(MapEdgeKind.configured, 'here/docs-bot', 'c/Bob/a/builder')), findsOneWidget);
    expect(find.text(en.mapWaitingOn('Build server')), findsOneWidget);
    expect(_key(_line(MapEdgeKind.traffic, 'here/volna', 'c/Emily Carter/a/chatgpt')), findsNothing);
    expect(find.text(en.mapTrafficLabel('2 h ago')), findsNothing);
    expect(_key(_line(MapEdgeKind.team, 'here/docs-bot', 'here/site.docs-1')), findsOneWidget);
    // Handles on the cards a line can start from; none on those the daemon decides for
    expect(_key('agent-map-handle-here/volna-r'), findsOneWidget);
    expect(_key('agent-map-handle-here/volna-l'), findsOneWidget);
    expect(_key('agent-map-handle-c/Bob/a/builder-l'), findsOneWidget, reason: 'facing this computer');
    expect(_key('agent-map-handle-c/Bob/a/builder-r'), findsNothing);
    expect(_key('agent-map-handle-here/helper-r'), findsNothing);
    expect(_key('agent-map-handle-here/site.docs-1-r'), findsNothing);
    expect(d.trafficCalls, greaterThan(0));
    // The choice survives while the window runs
    await t.tap(_key('nav-chats'));
    await _settle(t);
    await t.tap(_key('agents-button'));
    await _settle(t);
    expect(_key('agent-map'), findsOneWidget);
    await t.tap(_key('agents-view-list'));
    await _settle(t);
    expect(_key('agent-map'), findsNothing);
    expect(_key('agent-row-volna'), findsOneWidget);
  });

  testWidgets('drawing a line to an own computer\'s agent: the dialog, then tasks, peer_tasks and the password',
      (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    await _draw(t, 'here/docs-bot', 'c/Mac mini/a/codex');
    expect(_key('agent-connect-dialog'), findsOneWidget);
    expect(find.textContaining(en.mapConnectTitle('docs-bot', 'codex'), findRichText: true), findsOneWidget);
    expect(find.text(en.mapConnectHereLine('docs-bot', 'codex', 'Mac mini')), findsOneWidget);
    expect(find.text(en.mapConnectPeerLine('codex', 'docs-bot')), findsOneWidget);
    expect(find.text(en.mapConnectPeerApproval('Mac mini')), findsOneWidget);
    expect(_key('agent-connect-contact-side'), findsNothing);
    expect(t.widget<Checkbox>(_key('agent-connect-tasks')).value, isTrue, reason: 'an own computer: tasks by default');
    expect(t.widget<Checkbox>(_key('agent-connect-peer-tasks')).value, isTrue);
    expect(d.connectCalls, isEmpty, reason: 'nothing is sent before Connect');
    await _password(t);
    await _connect(t);
    expect(d.connectCalls.single, {
      'cmd': 'agent_connect',
      'name': 'docs-bot',
      'contact': 'Mac mini',
      'agent': 'codex',
      'tasks': true,
      'peer_tasks': true,
      'password': _pw,
    });
    expect(find.text(en.mapConnectDoneHere), findsOneWidget);
    expect(_key('agent-connect-requested'), findsOneWidget);
    expect(find.text(en.mapConnectRequested('Mac mini')), findsOneWidget);
    // Approve now: the Mac mini's request, from My devices, answered here (a denial needs nothing)
    final id = m.pendingConnects.single.id;
    await t.tap(_key('agent-connect-approve-now'));
    await _settle(t);
    expect(_key('agent-approve-dialog'), findsOneWidget);
    expect(_key('device-request-$id'), findsOneWidget);
    expect(find.descendant(of: _key('device-request-$id'), matching: find.textContaining(en.actionConnectAgent, findRichText: true)),
        findsOneWidget, reason: 'the action in words, not connect_agent');
    expect(find.text(en.reasonAgentConnect), findsOneWidget);
    await t.tap(_key('device-deny-$id'));
    await _settle(t);
    expect(d.deviceDecisions.single.$2, '$id deny');
    expect(find.text(en.mapConnectApproveDone('Mac mini')), findsOneWidget);
    // Closed: the canvas says the outcome too, with Approve now
    await t.tap(find.text(en.commonClose).last);
    await _settle(t);
    await t.tap(_key('agent-connect-close'));
    await _settle(t);
    expect(_status(MapStatusKind.done), findsOneWidget);
    expect(_statusText(t), en.mapStatusConnected('docs-bot', 'codex'));
    expect(_statusDetail(t), en.mapConnectRequested('Mac mini'));
    expect(_key('agent-map-status-action'), findsOneWidget);
  });

  testWidgets('a contact\'s agent: only this side, the contact decides theirs, no peer_tasks', (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    await _draw(t, 'here/volna', 'c/Bob/a/builder');
    expect(find.text(en.mapConnectContactSide('Bob')), findsOneWidget);
    expect(_key('agent-connect-peer-tasks'), findsNothing);
    expect(t.widget<Checkbox>(_key('agent-connect-tasks')).value, isFalse, reason: 'a contact\'s messages start as data');
    expect(find.text(en.mapConnectTasksHint('volna', 'Bob')), findsOneWidget);
    await t.tap(_key('agent-connect-tasks'));
    await t.pump();
    await _password(t);
    await _connect(t);
    expect(d.connectCalls.single,
        {'cmd': 'agent_connect', 'name': 'volna', 'contact': 'Bob', 'agent': 'builder', 'tasks': true, 'password': _pw});
    expect(find.text(en.mapConnectContactDecides('Bob')), findsOneWidget);
  });

  testWidgets('a person: no agent field; a line drawn from the other end works the same', (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    await _draw(t, 'c/Emily Carter/p', 'here/docs-bot');
    expect(find.text(en.mapConnectHerePerson('docs-bot', 'Emily Carter')), findsOneWidget);
    await _password(t);
    await _connect(t);
    expect(d.connectCalls.single, {'cmd': 'agent_connect', 'name': 'docs-bot', 'contact': 'Emily Carter', 'password': _pw});
    expect(find.text(en.mapConnectPersonSide('Emily Carter')), findsOneWidget);
  });

  testWidgets('the other side: unreachable with Ask again, an older Antenna there, a refusal, a wrong password',
      (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    d.otherSideFor['Mac mini'] = const OtherSide(state: OtherSideState.unreachable, message: 'timeout');
    await _draw(t, 'here/docs-bot', 'c/Mac mini/a/codex');
    await t.enterText(_key('owner-password'), 'wrong');
    await _connect(t);
    expect(find.text(en.errWrongPassword), findsOneWidget, reason: 'the form stays, with the daemon\'s refusal');
    await _password(t);
    await _connect(t);
    expect(find.text(en.mapConnectUnreachable('Mac mini')), findsOneWidget);
    await t.tap(_key('agent-connect-ask-again'));
    await _settle(t);
    await t.enterText(_key('owner-password').last, _pw);
    await t.tap(_key('password-ok'));
    await _settle(t);
    expect(d.connectCalls, hasLength(3));
    expect(d.connectCalls.last, d.connectCalls[1], reason: 'Ask again sends the same choices');

    await t.tap(_key('agent-connect-close'));
    await _settle(t);
    d.otherSideFor['Mac mini'] = const OtherSide(state: OtherSideState.unsupported);
    await _draw(t, 'here/volna', 'c/Mac mini/a/codex');
    await _password(t);
    await _connect(t);
    expect(_key('agent-connect-unsupported'), findsOneWidget);
    expect(find.text(en.mapConnectUnsupported('Mac mini')), findsOneWidget);

    await t.tap(_key('agent-connect-close'));
    await _settle(t);
    d.otherSideFor['Mac mini'] =
        const OtherSide(state: OtherSideState.refused, code: 'rate_limited', message: '8 connection requests already wait');
    await _draw(t, 'here/volna', 'c/Mac mini/a/codex');
    await _password(t);
    await _connect(t);
    expect(find.text(en.mapConnectRefused('Mac mini', '8 connection requests already wait · rate_limited')), findsOneWidget);
  });

  testWidgets('a card\'s body moves the card, its handle draws the line', (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    // The body dragged onto another computer's agent: no dialog, nothing sent, the agent stays on its computer
    final body = t.getTopLeft(_key('agent-map-node-here/volna')) + const Offset(20, 24);
    await _drag(t, body, t.getCenter(_key('agent-map-node-c/Bob/a/builder')) - body);
    expect(_key('agent-connect-dialog'), findsNothing);
    expect(d.connectCalls, isEmpty);
    expect(_status(MapStatusKind.info), findsOneWidget);
    expect(_statusText(t), en.mapMoveStays);
    expect(_map(t).layout!.slots['here']!.first, 'here/volna', reason: 'its order did not change');
  });

  testWidgets('click a line: the popover says what it means; Disconnect sends no password, pending then done',
      (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    const edge = 'configured:here/docs-bot>c/Bob/a/builder';
    // A click on the line itself, away from its dot
    final line = _map(t).layout!.lines.firstWhere((l) => l.edge.key == edge);
    await t.tapAt(_map(t).globalOf(line.at(0.3)));
    await _settle(t);
    expect(_key('agent-map-popover'), findsOneWidget);
    expect(t.widget<Text>(_key('agent-map-popover-title')).data, 'docs-bot → builder · Bob');
    expect(find.descendant(of: _key('agent-map-popover'), matching: find.text(en.mapConnectHereLine('docs-bot', 'builder', 'Bob'))),
        findsOneWidget);
    expect(find.text(en.mapDeleteHint), findsOneWidget);
    // Selected: drawn thicker, with a glow
    MapLinesPainter painter() =>
        t.widget<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MapLinesPainter)).painter!
            as MapLinesPainter;
    expect(painter().selected, edge);

    final gate = Completer<void>();
    d.disconnectGate = gate.future;
    await t.tap(_key('agent-map-popover-disconnect'));
    await t.pump();
    expect(_key('agent-map-popover'), findsNothing);
    expect(_status(MapStatusKind.pending), findsOneWidget);
    expect(_statusText(t), en.mapStatusDisconnecting('docs-bot', 'builder'));
    expect(painter().pending, {edge}, reason: 'the line is drawn faded while its disconnect runs');
    gate.complete();
    await _settle(t);
    expect(d.disconnectCalls.single, {'cmd': 'agent_disconnect', 'name': 'docs-bot', 'contact': 'Bob', 'agent': 'builder'});
    expect(_status(MapStatusKind.done), findsOneWidget);
    expect(_statusText(t), en.mapStatusDisconnected('docs-bot', 'builder'));
    expect(_statusDetail(t), en.mapConnectContactDecides('Bob'));
    expect(_key('agent-map-line-$edge'), findsNothing, reason: 'the daemon no longer has it');
  });

  testWidgets('Delete and Backspace disconnect the selected line with the defaults; a refusal says why; Escape deselects',
      (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    const edge = 'configured:here/volna>c/Mac mini/a/session-2';
    // A daemon's code this window does not know: its own words
    d.disconnectRefusal = const XControlException('link_busy', 'the link is busy, try again');
    await t.tap(_key('agent-map-line-$edge'));
    await _settle(t);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await _settle(t);
    expect(d.disconnectCalls.single, {'cmd': 'agent_disconnect', 'name': 'volna', 'contact': 'Mac mini', 'agent': 'session-2'},
        reason: 'the defaults: keep the tasks, ask the own computer; no password');
    expect(_status(MapStatusKind.failed), findsOneWidget);
    expect(_statusText(t), en.mapStatusDisconnectFailed('volna', 'session-2'));
    expect(_statusDetail(t), 'link_busy: the link is busy, try again');
    expect(_key('agent-map-line-$edge'), findsOneWidget, reason: 'refused: the line stays');

    await t.tap(_key('agent-map-line-$edge'));
    await _settle(t);
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _settle(t);
    expect(d.disconnectCalls, hasLength(2));
    expect(d.disconnectCalls.last, d.disconnectCalls.first);
    expect(_status(MapStatusKind.done), findsOneWidget);
    expect(_statusDetail(t), en.mapConnectRequested('Mac mini'));
    // Disconnected here; the Mac mini still points at volna until its owner approves there: the line waits for that
    expect(_key(_line(MapEdgeKind.waiting, 'here/volna', 'c/Mac mini/a/session-2')), findsOneWidget);
    expect(find.text(en.mapWaitingOn('Mac mini')), findsOneWidget);

    await t.tap(_key(_line(MapEdgeKind.configured, 'here/docs-bot', 'c/Bob/a/builder')));
    await _settle(t);
    expect(_key('agent-map-popover'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(t);
    expect(_key('agent-map-popover'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await _settle(t);
    expect(d.disconnectCalls, hasLength(2), reason: 'nothing selected: Delete sends nothing');
    // A click on empty canvas deselects too
    await t.tap(_key(_line(MapEdgeKind.configured, 'here/docs-bot', 'c/Bob/a/builder')));
    await _settle(t);
    final s = _map(t);
    await t.tapAt(s.globalOf(s.layout!.content.bottomLeft + const Offset(4, 40)));
    await _settle(t);
    expect(_key('agent-map-popover'), findsNothing);
  });

  testWidgets('Options… opens the disconnect dialog with its choices', (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    const edge = 'configured:here/volna>c/Mac mini/a/session-2';
    await t.tap(_key('agent-map-line-$edge'));
    await _settle(t);
    await t.tap(_key('agent-map-popover-options'));
    await _settle(t);
    expect(_key('agent-disconnect-dialog'), findsOneWidget);
    expect(find.text(en.mapDisconnectWhat('volna')), findsOneWidget);
    expect(t.widget<Checkbox>(_key('agent-disconnect-tasks')).value, isFalse);
    expect(t.widget<Checkbox>(_key('agent-disconnect-ask')).value, isTrue);
    expect(_key('owner-password'), findsNothing);
    await t.tap(_key('agent-disconnect-tasks'));
    await t.pump();
    await t.tap(_key('agent-disconnect-ok'));
    await _settle(t);
    expect(d.disconnectCalls.single,
        {'cmd': 'agent_disconnect', 'name': 'volna', 'contact': 'Mac mini', 'agent': 'session-2', 'tasks': false});
    expect(find.text(en.mapDisconnectDone), findsOneWidget);
    expect(find.text(en.mapConnectRequested('Mac mini')), findsOneWidget);
    expect(m.agents.firstWhere((a) => a.name == 'volna').counterpart, isNull);
    await t.tap(_key('agent-disconnect-close'));
    await _settle(t);
    expect(_statusText(t), en.mapStatusDisconnected('volna', 'session-2'));

    // A contact's agent, from the agent's menu: nothing to ask
    await t.tap(_key('agent-map-menu-docs-bot'));
    await _settle(t);
    await t.tap(_key('agent-map-disconnect-docs-bot'));
    await _settle(t);
    expect(_key('agent-disconnect-ask'), findsNothing);
    await t.tap(_key('agent-disconnect-ok'));
    await _settle(t);
    expect(d.disconnectCalls.last, {'cmd': 'agent_disconnect', 'name': 'docs-bot', 'contact': 'Bob', 'agent': 'builder'});
  });

  testWidgets('recent messages: off by default; on, grey, labelled, without arrows, never disconnected; kept', (t) async {
    final (m, d) = await _setup();
    final look = Appearance();
    await _open(t, m, look: look);
    const edge = 'traffic:here/volna>c/Emily Carter/a/chatgpt';
    expect(_map(t).layout!.lines.where((l) => l.edge.kind == MapEdgeKind.traffic), isEmpty);
    expect(t.widget<Switch>(_key('agent-map-recent')).value, isFalse);
    await t.tap(_key('agent-map-recent'));
    await _settle(t);
    expect(look.agentMap.recent, isTrue, reason: 'saved with the layout');
    expect(find.text(en.mapLegendTraffic), findsOneWidget);
    expect(find.text(en.mapTrafficLabel('2 h ago')), findsOneWidget);
    final traffic = _map(t).layout!.lines.where((l) => l.edge.kind == MapEdgeKind.traffic).single;
    expect(traffic.edge.key, edge);
    expect((traffic.edge.toOther, traffic.edge.toLocal, traffic.edge.removable), (false, false, false),
        reason: 'history: no arrowheads, nothing to remove');
    final style = lineStyle(MapEdgeKind.traffic);
    expect(style.color, XColors.textMute.withValues(alpha: 0.6), reason: 'grey');
    expect(style.width, lessThan(lineStyle(MapEdgeKind.configured).width), reason: 'thin');
    // Selected: it explains itself, with nothing to disconnect
    await t.tap(_key('agent-map-line-$edge'));
    await _settle(t);
    expect(_key('agent-map-popover'), findsOneWidget);
    expect(t.widget<Text>(_key('agent-map-popover-title')).data,
        '${en.mapTrafficTitle('volna', 'chatgpt')} · Emily Carter');
    expect(find.text(en.mapTrafficCounts(3, 2, '2 h ago')), findsOneWidget);
    expect(find.text(en.mapTrafficNotLine), findsOneWidget);
    expect(find.text(en.mapTrafficHow('volna')), findsOneWidget);
    expect(_key('agent-map-popover-disconnect'), findsNothing);
    expect(_key('agent-map-popover-options'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _settle(t);
    expect(d.disconnectCalls, isEmpty, reason: 'Delete on recent messages sends nothing');
    expect(d.calls.where((c) => c == 'agent_disconnect'), isEmpty);
    // A team line explains itself too, and is not removable
    await t.tap(_key(_line(MapEdgeKind.team, 'here/docs-bot', 'here/site.docs-1')));
    await _settle(t);
    expect(find.text(en.mapTeamLine('docs-bot', 'site', 'site.docs-1')), findsOneWidget);
    expect(_key('agent-map-popover-disconnect'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await _settle(t);
    expect(d.disconnectCalls, isEmpty);
    // Off again: gone
    await t.tap(_key('agent-map-recent'));
    await _settle(t);
    expect(find.text(en.mapTrafficLabel('2 h ago')), findsNothing);
    expect(look.agentMap.recent, isFalse);
  });

  testWidgets('hover over a line: a tip says what it means', (t) async {
    final (m, _) = await _setup();
    await _open(t, m);
    final s = _map(t);
    final line = s.layout!.lines.firstWhere((l) => l.edge.key == 'configured:here/volna>c/Mac mini/a/session-2');
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(mouse.hover(s.globalOf(line.at(0.3))));
    await t.pump();
    expect(_key('agent-map-line-tip'), findsOneWidget);
    expect(find.descendant(of: _key('agent-map-line-tip'), matching: find.text('volna ↔ session-2 · Mac mini')), findsOneWidget);
    expect(find.descendant(of: _key('agent-map-line-tip'), matching: find.text(en.mapTasksTip('volna', 'Mac mini'))),
        findsOneWidget);
    await t.sendEventToBinding(mouse.hover(s.globalOf(s.layout!.content.bottomLeft + const Offset(4, 40))));
    await t.pump();
    expect(_key('agent-map-line-tip'), findsNothing);
  });

  testWidgets('groups and cards move; the arrangement is saved in the settings file and comes back', (t) async {
    final dir = Directory.systemTemp.createTempSync('agent-map-prefs');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppearanceStore('${dir.path}/window.json');
    // A window that has shown its one-time notices already
    File(store.path)
        .writeAsStringSync(json.encode({'theme': 'light', 'lang': 'en', 'code_offered': true, 'self_notice_shown': true}));
    final (m, d) = await _setup();
    await _open(t, m, look: Appearance.load(store));
    final s = _map(t);
    final scale = s.view.scale;
    final before = s.layout!.clusters['c/Mac mini']!;
    // The group by its header
    final header = t.getTopLeft(_key('agent-map-cluster-c/Mac mini')) + const Offset(80, 16);
    await _drag(t, header, const Offset(0, 240));
    final after = s.layout!.clusters['c/Mac mini']!;
    expect(after.top - before.top, closeTo(240 / scale, 1));
    expect(after.left, closeTo(before.left, 1));
    // A card two slots down
    final body = t.getTopLeft(_key('agent-map-node-here/volna')) + const Offset(20, 24);
    await _drag(t, body, Offset(0, 2 * (MapMetrics.node + MapMetrics.nodeGap) * scale + 6));
    expect(s.layout!.slots['here'], ['here/docs-bot', 'here/site.docs-1', 'here/volna', 'here/reviewer', 'here/helper']);
    expect(d.connectCalls, isEmpty);
    expect(d.disconnectCalls, isEmpty);
    await t.pump(const Duration(seconds: 1));
    final saved = (json.decode(File(store.path).readAsStringSync()) as Map)['agent_map'] as Map;
    final clusters = saved['clusters'] as Map;
    expect((clusters['c/Mac mini'] as List)[1], closeTo(after.top, 0.1));
    expect(clusters.keys, containsAll(['here', 'c/Mac mini', 'c/Build server', 'c/Bob', 'c/Emily Carter']),
        reason: 'from the first move on every group stays where it is');
    expect(saved['order'], {'here': ['here/docs-bot', 'here/site.docs-1', 'here/volna', 'here/reviewer', 'here/helper']});
    expect(saved.containsKey('recent'), isFalse);

    // A new window (after a restart): the same arrangement, from the file
    await t.pumpWidget(const SizedBox());
    await _open(t, m, look: Appearance.load(store));
    final again = _map(t).layout!;
    expect(again.clusters['c/Mac mini']!.top, closeTo(after.top, 0.1));
    expect(again.slots['here']!.first, 'here/docs-bot');

    // Arrange automatically: back to the default, the whole map in view
    await t.tap(_key('agent-map-arrange'));
    await _settle(t);
    expect(_map(t).layout!.clusters['c/Mac mini']!.top, closeTo(before.top, 0.1));
    expect(_map(t).layout!.slots['here']!.first, 'here/volna');
    await t.pump(const Duration(seconds: 1));
    final reset = (json.decode(File(store.path).readAsStringSync()) as Map)['agent_map'] as Map;
    expect(reset.containsKey('clusters'), isFalse);
    expect(reset.containsKey('order'), isFalse);
    expect(reset['view'], isA<List<Object?>>());
  });

  testWidgets('pan and zoom: the wheel pans, Ctrl or Cmd with the wheel and a pinch zoom, the buttons, Fit', (t) async {
    final (m, _) = await _setup();
    final look = Appearance();
    await _open(t, m, look: look);
    final s = _map(t);
    final v = s.view;
    final fit = v.scale;
    expect(fit, lessThanOrEqualTo(1.0));
    expect(find.text(en.mapZoomLevel((fit * 100).round())), findsOneWidget);
    final center = t.getCenter(_key('agent-map-canvas'));
    // Dragging the empty canvas pans
    var pan = v.pan;
    final empty = s.globalOf(s.layout!.content.bottomLeft + const Offset(4, 40));
    await _drag(t, empty, const Offset(-60, -30));
    expect(v.pan, pan + const Offset(-60, -30));
    expect(v.scale, fit);
    // The mouse wheel pans
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(mouse.hover(center));
    pan = v.pan;
    await t.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await t.pump();
    expect(v.pan, pan - const Offset(0, 100));
    expect(v.scale, fit);
    // Ctrl with the wheel zooms around the pointer
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(v.scale, greaterThan(fit));
    // A trackpad: two fingers pan, a pinch zooms
    final pad = await t.createGesture(kind: PointerDeviceKind.trackpad);
    await pad.panZoomStart(center);
    pan = v.pan;
    await pad.panZoomUpdate(center, pan: const Offset(30, -20));
    await t.pump();
    expect(v.pan, pan + const Offset(30, -20));
    final before = v.scale;
    await pad.panZoomUpdate(center, pan: const Offset(30, -20), scale: 1.5);
    await t.pump();
    expect(v.scale, closeTo((before * 1.5).clamp(0.4, 2.0), 1e-9));
    await pad.panZoomEnd();
    await t.pump();
    // The buttons: 100 %, +, −, never beyond 0.4–2.0
    await t.tap(_key('agent-map-zoom-level'));
    await t.pump();
    expect(v.scale, 1.0);
    expect(find.text(en.mapZoomLevel(100)), findsOneWidget);
    await t.tap(_key('agent-map-zoom-in'));
    await t.pump();
    expect(v.scale, closeTo(1.2, 1e-9));
    for (var i = 0; i < 10; i++) {
      await t.tap(_key('agent-map-zoom-in'));
    }
    await t.pump();
    expect(v.scale, 2.0);
    for (var i = 0; i < 20; i++) {
      await t.tap(_key('agent-map-zoom-out'));
    }
    await t.pump();
    expect(v.scale, 0.4);
    // Fit: the whole map in view again
    await t.tap(_key('agent-map-zoom-fit'));
    await t.pump();
    expect(v.scale, closeTo(fit, 1e-9));
    for (final r in s.layout!.clusters.values) {
      final tl = v.toCanvas(r.topLeft);
      final br = v.toCanvas(r.bottomRight);
      expect(tl.dx >= 0 && tl.dy >= 0 && br.dx <= v.size.width && br.dy <= v.size.height, isTrue, reason: '$r');
    }
    await t.pump(const Duration(seconds: 1));
    expect(look.agentMap.view?.scale, closeTo(fit, 1e-3), reason: 'the view is kept too');
  });

  testWidgets('own computers on the left whatever else there is: the only other computer, no report, no devices',
      (t) async {
    // The field case: one own computer (∞) and no other contact; it has not reported itself yet.
    final d = FakeDaemon(contacts: [contact('atlas server', 71, trust: 5, peerKind: 'agent')])
      ..devicesEnabled = true
      ..agentList = [mapAgent('claude-code', alive: true)];
    d.devicesState = DevicesReply(
      self: const ThisDevice(name: 'Mayas-MacBook-Pro', os: 'macos', arch: 'aarch64', version: 'antennad 0.2.0'),
      devices: [DeviceInfo(contact: 'atlas server', linkId: contact('atlas server', 71).linkId, presence: 'online', supported: true)],
    );
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    await m.refreshAgentMap();
    await _open(t, m);
    final lay = _map(t).layout!;
    expect(lay.clusters['c/atlas server']!.center.dx, lessThan(lay.clusters['here']!.center.dx), reason: 'on the left');
    expect(t.getCenter(_key('agent-map-cluster-c/atlas server')).dx, lessThan(t.getCenter(_key('agent-map-cluster-here')).dx));
    expect(_key('agent-map-report-missing-c/atlas server'), findsOneWidget);
    expect(find.text('${en.mapReportMissing} · ${en.devicesOnline}'), findsOneWidget);
    // And a contact next to it goes right
    d.contactList.add(contact('Bob', 63, trust: 3));
    await m.refreshContacts();
    await _settle(t);
    final both = _map(t).layout!;
    expect(both.clusters['c/atlas server']!.center.dx, lessThan(both.clusters['here']!.center.dx));
    expect(both.clusters['c/Bob']!.center.dx, greaterThan(both.clusters['here']!.center.dx));
  });

  testWidgets('two agents of this computer: the local dialog, `local` sent, the line inside the group, Delete', (t) async {
    final (m, d) = await _setup(local: true);
    await _open(t, m);
    expect(m.localConnectionsSupported, isTrue);
    await _draw(t, 'here/volna', 'here/reviewer');
    expect(_key('local-connect-dialog'), findsOneWidget);
    expect(find.textContaining(en.mapLocalTitle('volna', 'reviewer'), findRichText: true), findsOneWidget);
    expect(find.text(en.mapConnectPeerLine('volna', 'reviewer')), findsOneWidget, reason: 'the line itself');
    expect(find.text(en.mapLocalAsk('reviewer', 'volna')), findsOneWidget);
    expect(find.text(en.mapConnectTasks('volna', 'reviewer')), findsOneWidget);
    expect(find.text(en.mapConnectTasks('reviewer', 'volna')), findsOneWidget);
    for (final k in ['local-connect-ask', 'local-connect-peer-tasks', 'local-connect-tasks']) {
      expect(t.widget<Checkbox>(_key(k)).value, isTrue, reason: k);
    }
    for (final s in [en.mapLocalStays, en.mapLocalTaint('volna', 'reviewer'), en.mapLocalLevels, en.mapLocalChains]) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.text(en.commonSameAs('antenna agent connect volna --local reviewer --tasks --peer-tasks')), findsOneWidget);
    expect(d.connectCalls, isEmpty);
    await _password(t);
    await t.tap(_key('local-connect-ok'));
    await _settle(t);
    expect(d.connectCalls.single,
        {'cmd': 'agent_connect', 'name': 'volna', 'local': 'reviewer', 'tasks': true, 'peer_tasks': true, 'password': _pw});
    expect(find.text(en.mapConnectDoneHere), findsOneWidget);
    await t.tap(_key('local-connect-close'));
    await _settle(t);
    expect(_statusText(t), en.mapStatusConnected('volna', 'reviewer'));
    expect(_statusDetail(t), isNull);
    // One line both ways, tasks at both ends, inside the group
    const edge = 'configured:here/volna>here/reviewer';
    final lay = _map(t).layout!;
    final line = lay.lines.firstWhere((l) => l.edge.key == edge);
    expect((line.edge.mutual, line.edge.tasksLocal, line.edge.tasksOther, line.edge.inside), (true, true, true, true));
    final group = lay.clusters['here']!;
    for (var i = 0; i <= 32; i++) {
      expect(group.contains(line.at(i / 32)), isTrue, reason: 'the line stays inside the group');
    }
    expect(_key('agent-map-tasks-$edge-here'), findsOneWidget);
    expect(_key('agent-map-tasks-$edge-there'), findsOneWidget);
    // Selected and deleted: `local`, no password
    await t.tap(_key('agent-map-line-$edge'));
    await _settle(t);
    expect(t.widget<Text>(_key('agent-map-popover-title')).data, 'volna ↔ reviewer · ${en.devicesThisComputer}');
    expect(find.text(en.mapLocalDropsUnread), findsOneWidget, reason: 'the daemon drops their unread messages');
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await _settle(t);
    expect(d.disconnectCalls.single, {'cmd': 'agent_disconnect', 'name': 'volna', 'local': 'reviewer'});
    expect(_key('agent-map-line-$edge'), findsNothing);
    expect(_statusText(t), en.mapStatusDisconnected('volna', 'reviewer'));
    // From the keyboard: Connect to… lists this computer's agents too, one way only
    await t.tap(_key('agent-map-menu-volna'));
    await _settle(t);
    await t.tap(_key('agent-map-connect-to-volna'));
    await _settle(t);
    expect(_key('agent-pick-here/volna'), findsNothing);
    expect(_key('agent-pick-here/helper'), findsNothing, reason: 'a local-model agent is not an end');
    await t.tap(_key('agent-pick-here/docs-bot'));
    await _settle(t);
    await t.tap(_key('local-connect-ask'));
    await t.tap(_key('local-connect-tasks'));
    await t.pump();
    await _password(t);
    await t.tap(_key('local-connect-ok'));
    await _settle(t);
    expect(d.connectCalls.last, {
      'cmd': 'agent_connect',
      'name': 'volna',
      'local': 'docs-bot',
      'tasks': false,
      'peer_tasks': true,
      'ask': false,
      'password': _pw,
    });
    expect(find.text(en.mapLocalNotAsked('docs-bot')), findsOneWidget);
  });

  testWidgets('two agents of this computer with an older daemon: a note, nothing sent', (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    expect(m.localConnectionsSupported, isFalse, reason: 'no local_routes in agent_list');
    await _draw(t, 'here/volna', 'here/docs-bot');
    expect(_key('local-connect-dialog'), findsNothing);
    expect(_statusText(t), en.mapDropLocalUnsupported);
    // An agent the daemon decides for has no handle, and a line dropped on it says why
    expect(_key('agent-map-handle-here/helper-r'), findsNothing);
    await _draw(t, 'c/Bob/a/builder', 'here/helper');
    expect(_key('agent-connect-dialog'), findsNothing);
    expect(_statusText(t), en.mapWhyLocal);
    await _draw(t, 'c/Bob/a/builder', 'here/site.docs-1');
    expect(_statusText(t), en.mapWhyWorker('site'));
    await _draw(t, 'c/Bob/a/builder', 'c/Mac mini/a/codex');
    expect(_statusText(t), en.mapDropNoLocal);
    expect(d.connectCalls, isEmpty);
    expect(d.calls.where((c) => c == 'agent_connect'), isEmpty);
  });

  testWidgets('a daemon that refuses `local` as an unknown field: said plainly, connections stay', (t) async {
    final (m, d) = await _setup(local: true);
    await _open(t, m);
    d.connectRefusal = const XControlException(
        XErrorCode.badRequest, 'bad message: unknown field `local`, expected one of `name`, `contact`, `agent`');
    await _draw(t, 'here/volna', 'here/reviewer');
    await _password(t);
    await t.tap(_key('local-connect-ok'));
    await _settle(t);
    expect(find.text(en.mapDropLocalUnsupported), findsOneWidget);
    expect(m.localConnectionsAbsent, isTrue);
    expect(m.connectionsAbsent, isFalse, reason: 'connections to other computers still work');
    expect(m.connectionsSupported, isTrue);
    await t.tap(find.text(en.commonCancel));
    await _settle(t);
    expect(_statusText(t), en.mapStatusConnectFailed('volna', 'reviewer'));
    expect(_statusDetail(t), en.mapDropLocalUnsupported);
    final sent = d.connectCalls.length;
    await _draw(t, 'here/volna', 'here/docs-bot');
    expect(_key('local-connect-dialog'), findsNothing);
    expect(_statusText(t), en.mapDropLocalUnsupported);
    expect(d.connectCalls, hasLength(sent));
  });

  testWidgets('the keyboard path: Connect to… lists the other computers\' agents and persons', (t) async {
    final (m, d) = await _setup();
    await _open(t, m);
    await t.tap(_key('agent-map-menu-volna'));
    await _settle(t);
    await t.tap(_key('agent-map-connect-to-volna'));
    await _settle(t);
    expect(_key('agent-pick-dialog'), findsOneWidget);
    expect(_key('agent-pick-c/Bob/p'), findsOneWidget);
    expect(_key('agent-pick-here/docs-bot'), findsNothing, reason: 'nothing of this computer without local connections');
    await t.tap(_key('agent-pick-c/Build server/a/lead'));
    await _settle(t);
    expect(find.textContaining(en.mapConnectTitle('volna', 'lead'), findRichText: true), findsOneWidget);
    await _password(t);
    await _connect(t);
    expect(d.connectCalls.single['agent'], 'lead');
    expect(d.connectCalls.single['peer_tasks'], isTrue);
  });

  testWidgets('an older daemon: the agents without connections, a line saying why, nothing sent', (t) async {
    final (m, d) = await _setup(enabled: false);
    await _open(t, m);
    expect(m.connectionsSupported, isFalse);
    expect(_key('agent-map-absent'), findsOneWidget);
    expect(find.text(en.mapAbsent), findsOneWidget);
    expect(_key('agent-map-node-here/volna'), findsOneWidget);
    expect(_key('agent-map-node-c/Bob/a/builder'), findsOneWidget);
    expect(_key('agent-map-menu-volna'), findsNothing);
    expect(_key('agent-map-handle-here/volna-r'), findsNothing, reason: 'no line to draw');
    final body = t.getTopLeft(_key('agent-map-node-here/volna')) + const Offset(20, 24);
    await _drag(t, body, t.getCenter(_key('agent-map-node-c/Bob/a/builder')) - body);
    expect(_key('agent-connect-dialog'), findsNothing);
    expect(d.calls.where((c) => c == 'agent_connect'), isEmpty);
  });

  testWidgets('the agent\'s card: its default counterpart and a line only the other side drew, each Disconnect…',
      (t) async {
    final (m, d) = await _setup(tweak: (d) {
      final s = d.devicesState;
      final mini = s.devices.first;
      d.devicesState = DevicesReply(self: s.self, devices: [
        DeviceInfo(
          contact: mini.contact,
          linkId: mini.linkId,
          presence: 'online',
          supported: true,
          status: DeviceView(atMs: 0, name: 'm', os: 'macos', arch: 'a', version: 'v', agents: [
            mini.status!.agents.first,
            const DeviceAgent(name: 'codex', app: 'codex', state: 'idle', counterpart: 'reviewer'),
          ]),
        ),
        ...s.devices.skip(1),
      ]);
    });
    await _open(t, m, map: false);
    expect(find.text(en.agentCounterpart('session-2 · Mac mini')), findsOneWidget);
    expect(find.text(en.agentCounterpart('builder · Bob')), findsOneWidget);
    expect(find.text(en.agentConnectedFrom('codex · Mac mini')), findsOneWidget);
    expect(find.text(en.agentConnectedFrom('session-2 · Mac mini')), findsNothing, reason: 'both ways: one line');
    await t.ensureVisible(_key('agent-connected-from-disconnect-reviewer-Mac mini-codex'));
    await t.tap(_key('agent-connected-from-disconnect-reviewer-Mac mini-codex'));
    await _settle(t);
    expect(find.text(en.mapDisconnectWhatThere('codex', 'Mac mini', 'reviewer')), findsOneWidget);
    await t.tap(_key('agent-disconnect-ok'));
    await _settle(t);
    expect(d.disconnectCalls.single,
        {'cmd': 'agent_disconnect', 'name': 'reviewer', 'contact': 'Mac mini', 'agent': 'codex'});
  });

  testWidgets('the agent\'s card: a local counterpart and a local connection, each Disconnect… without a password',
      (t) async {
    final (m, d) = await _setup(local: true, tweak: (d) {
      d.agentList = [
        for (final a in d.agentList)
          switch (a.name) {
            'volna' => mapAgent('volna',
                counterpart: const Counterpart(contact: '', agent: 'reviewer', local: true),
                tasksFrom: const ['Mac mini'],
                localRoutes: const [LocalRoute(agent: 'reviewer', tasks: true), LocalRoute(agent: 'docs-bot')]),
            _ => a,
          },
      ];
    });
    await _open(t, m, map: false);
    expect(find.text(en.agentCounterpart('reviewer · ${en.devicesThisComputer}')), findsOneWidget);
    expect(find.text(en.agentLocalRoute('docs-bot')), findsOneWidget);
    await t.ensureVisible(_key('agent-local-route-disconnect-volna-docs-bot'));
    await t.tap(_key('agent-local-route-disconnect-volna-docs-bot'));
    await _settle(t);
    expect(find.text(en.mapLocalDisconnectWhat('volna', 'docs-bot')), findsOneWidget);
    expect(find.text(en.mapLocalDropsUnread), findsOneWidget);
    expect(_key('owner-password'), findsNothing);
    await t.tap(_key('local-disconnect-ok'));
    await _settle(t);
    expect(d.disconnectCalls.single, {'cmd': 'agent_disconnect', 'name': 'volna', 'local': 'docs-bot'});
  });
}
