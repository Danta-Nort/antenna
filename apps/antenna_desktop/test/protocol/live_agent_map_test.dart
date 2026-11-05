// SPDX-License-Identifier: AGPL-3.0-only
// The agent map (x-control/7, CONTROL §30, D-123; experimental) against REAL daemons: the laptop and the Mac mini are
// each other's own computers (∞ both ways). The laptop's window (AppModel) draws a line from its volna to the mini's
// session-2 with the password: its side is set at once, and the mini makes an approval request; the window sees that
// request in the mini's status and the line waits. The mini's owner approves it there with the mini's password: the
// mini's agent list shows volna as session-2's counterpart, the laptop's My devices shows session-2 connected to volna
// and taking its tasks, and the window draws one line both ways with the tasks marks. session-2 then writes without
// naming anyone, which reaches volna, and the window's `agent_traffic` counts it. Disconnecting from the window takes
// no password and asks the mini again. Then two agents of one computer (D-UI-47): the window connects volna with
// reviewer (`agent_connect` with `local`), the daemon's `agent_list` shows the route both ways and each one's
// counterpart, and the line's default disconnect removes it without a password; a daemon built before local
// connections (no `session.local_routes`) skips that test with the reason.
// Run: ANTENNAD_BIN=<path to a debug antennad> flutter test --tags live test/protocol/live_agent_map_test.dart
// Not on Windows (D-135): its afunix.sys bugchecks the machine when a process with a unix socket connection ends.
@TestOn('!windows')
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_map.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> _until(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 45), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// Pair [a] (inviting) and [b] at [trust] both ways; [a] calls [b] by [bn]'s name and the other way round.
Future<void> _pair(XControlClient a, XdNode an, XControlClient b, XdNode bn, int trust) async {
  final inv = Events(a.open(InviteRequest(trust: trust, ttlSecs: 120, label: bn.name, password: an.password)));
  final created = await inv.next<InviteCreated>();
  final join = Events(b.open(JoinRequest(
    link: created.link,
    trust: trust,
    label: an.name,
    connectTimeoutMs: 5000,
    password: bn.password,
  )));
  final sas = await inv.next<SasEvent>();
  await join.next<NeedInput>((e) => e.isSasCode);
  join.dialog.input(SasCodeInput(sas.code));
  await inv.next<NeedInput>((e) => e.isConfirm);
  inv.dialog.input(ConfirmInput(true, code: sas.code));
  await join.dialog.result;
}

/// One agent request over the agent's own connection (its token): the `ok` body, or the `err` body as an exception.
Future<Map<String, Object?>> _agentCall(String socket, String token, Map<String, Object?> req) async {
  final s = await Socket.connect(InternetAddress(socket, type: InternetAddressType.unix), 0);
  try {
    s.write('${jsonEncode({'hello': {'proto': 'x-control/7', 'role': 'agent', 'token': token}})}\n');
    s.write('${jsonEncode({'req': req})}\n');
    await for (final line in s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter())) {
      final v = jsonDecode(line) as Map<String, Object?>;
      if (v['err'] case final e?) throw StateError('agent request refused: $e');
      if (v['ok'] case final Map<String, Object?> ok) return ok;
    }
    throw StateError('no reply');
  } finally {
    s.destroy();
  }
}

AgentMapGraph _graph(AppModel w) => buildAgentMap(
      agents: w.agents,
      thisName: w.devices?.self.name ?? '',
      devices: w.ownDevices,
      contacts: w.contacts,
      traffic: w.agentTraffic?.pairs ?? const [],
      pending: w.pendingConnects,
    );

void main() {
  final antennad = findXd();

  test('the window connects volna to the mini\'s session-2; approved there, both sides show the line', () async {
    final root = await tempRoot();
    final lap = XdNode('lap', root, antennad!);
    final mini = XdNode('mini', root, antennad);
    await Future.wait([lap.start(), mini.start()]);
    AppModel? m;
    try {
      final l = XControlClient(lap.socket);
      final c = XControlClient(mini.socket);
      await l.init(lap.password);
      await c.init(mini.password);
      await openOwnerSession(l, lap.password);
      await openOwnerSession(c, mini.password);
      await _pair(l, lap, c, mini, 5);
      await l.agentAdd('volna', localLevel: 0, password: lap.password, links: ['mini']);
      final s2 = await c.agentAdd('session-2', localLevel: 0, password: mini.password, links: ['lap']);

      final w = AppModel(connector: XControlClient.new, socketPath: lap.socket);
      m = w;
      await w.connect();
      expect(await w.login(lap.password), isNull);
      await _until(() async {
        await w.refreshDevices();
        return w.ownDevices.where((d) => d.contact == 'mini').firstOrNull?.status?.agents.any((a) => a.name == 'session-2') ??
            false;
      }, what: 'the mini reports session-2 to the laptop');
      await w.refreshAgentMap();
      expect(w.connectionsSupported, isTrue, reason: 'this daemon knows agent_traffic');
      expect(w.agentTraffic, isNotNull);

      // Drawn on the map: from volna to the mini's session-2
      var g = _graph(w);
      final drop = checkDrop(g, hereNodeId('volna'), remoteNodeId('mini', 'session-2'));
      expect(drop, isA<DropConnect>());
      final DropConnect(:local, :other) = drop! as DropConnect;
      expect((local.name, other.name), ('volna', 'session-2'));
      expect(g.own(other), isTrue);
      final out = await w.connectAgent(connectRequestFor(
          local: local, other: other, own: true, tasks: true, currentTasks: false, peerTasks: true, password: lap.password));
      expect(out.error, isNull);
      final side = out.reply!.otherSide;
      expect(side.state, OtherSideState.requested, reason: '${side.code} ${side.message}');
      final id = side.id!;
      expect(w.agents.firstWhere((a) => a.name == 'volna').counterpart, const Counterpart(contact: 'mini', agent: 'session-2'));
      expect(w.agents.firstWhere((a) => a.name == 'volna').tasksFrom, contains('mini'));
      print('CONNECT: this side set, request $id made on the mini');

      // On the mini: the request in its approvals, in its daemon's words
      final asked = (await c.approvals()).approvals.where((a) => a.id == id).single;
      expect((asked.action, asked.state), ('connect_agent', 'pending'));
      expect(asked.reasons, ['agent_connect']);
      expect(asked.quote, contains('session-2'));
      expect((await c.agents()).firstWhere((a) => a.name == 'session-2').counterpart, isNull, reason: 'not before approval');

      // The window sees the request in the mini's status: the line waits
      await _until(() async {
        await w.refreshDevices();
        return w.waitingRequest(w.ownDevices, 'mini', id) != null;
      }, what: 'the request in the laptop\'s view of the mini');
      g = _graph(w);
      final waiting = g.edges.where((e) => e.kind == MapEdgeKind.waiting).single;
      expect((waiting.local, waiting.other, waiting.waitingOn), (hereNodeId('volna'), remoteNodeId('mini', 'session-2'), 'mini'));

      // Approved there, with the mini's own password
      await c.approve(id, mini.password);
      await _until(() async {
        final a = (await c.agents()).firstWhere((a) => a.name == 'session-2');
        return a.counterpart == const Counterpart(contact: 'lap', agent: 'volna');
      }, what: 'the mini applies the approved request');
      expect((await c.agents()).firstWhere((a) => a.name == 'session-2').tasksFrom, contains('lap'));

      // The laptop's My devices: session-2 is connected to volna and takes the laptop's messages as tasks
      await _until(() async {
        await w.refreshDevices();
        final x = w.ownDevices.firstWhere((d) => d.contact == 'mini').status?.agents.where((a) => a.name == 'session-2').firstOrNull;
        return x?.counterpart == 'volna' && x!.takesTasks;
      }, what: 'the mini says session-2 is connected to volna');
      g = _graph(w);
      final line = g.edges.where((e) => e.kind == MapEdgeKind.configured).single;
      expect((line.mutual, line.tasksLocal, line.tasksOther), (true, true, true));
      expect(g.edges.where((e) => e.kind == MapEdgeKind.waiting), isEmpty, reason: 'answered: no longer waiting');
      print('APPROVED: one line both ways, tasks at both ends');

      // session-2 writes without naming anyone: it goes to volna, and the laptop's traffic counts it
      final sent = await _agentCall(mini.socket, s2.token, {'cmd': 'send', 'text': 'status?', 'wait_ms': 3000});
      expect(sent['to_agent'], 'volna', reason: '$sent');
      await _until(() async {
        await w.refreshTraffic();
        return w.agentTraffic!.pairs
            .any((p) => p.agent == 'volna' && p.contact == 'mini' && p.peerAgent == 'session-2' && p.received >= 1);
      }, what: 'the laptop\'s traffic of volna and session-2');
      print('TRAFFIC: ${[for (final p in w.agentTraffic!.pairs) '${p.agent}<->${p.contact}/${p.peerAgent} +${p.sent}/-${p.received}']}');

      // Disconnected from the window: no password; the mini is asked again
      final off = await w.disconnectAgent(
          disconnectRequestFor(agent: 'volna', contact: 'mini', peerAgent: 'session-2', own: true, stopTasks: true));
      expect(off.error, isNull);
      expect(off.reply!.otherSide.state, OtherSideState.requested);
      expect(w.agents.firstWhere((a) => a.name == 'volna').counterpart, isNull);
      expect(w.agents.firstWhere((a) => a.name == 'volna').tasksFrom, isNot(contains('mini')));
      final again = (await c.approvals()).approvals.where((a) => a.id == off.reply!.otherSide.id).single;
      expect(again.action, 'disconnect_agent');
      print('DISCONNECT: this side cleared without a password, request ${again.id} on the mini');
    } finally {
      m?.dispose();
      await Future.wait([lap.stop(), mini.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 3)));

  test('the window connects two agents of one computer; agent_list shows the route both ways; disconnect removes it',
      () async {
    final root = await tempRoot();
    final lap = XdNode('lap', root, antennad!);
    await lap.start();
    AppModel? m;
    try {
      final l = XControlClient(lap.socket);
      await l.init(lap.password);
      await openOwnerSession(l, lap.password);
      await l.agentAdd('volna', localLevel: 0, password: lap.password);
      await l.agentAdd('reviewer', localLevel: 0, password: lap.password);

      final w = AppModel(connector: XControlClient.new, socketPath: lap.socket);
      m = w;
      await w.connect();
      expect(await w.login(lap.password), isNull);
      await w.refreshAgentMap();
      if (!w.localConnectionsSupported) {
        markTestSkipped('this antennad sends no session.local_routes: it was built before local connections');
        return;
      }

      // Drawn on the map: from volna to reviewer, both on this computer
      var g = _graph(w);
      final drop = checkDrop(g, hereNodeId('volna'), hereNodeId('reviewer'), localRoutes: true);
      expect(drop, isA<DropConnectLocal>());
      final out = await w.connectLocal(
          LocalConnectRequest(name: 'volna', local: 'reviewer', tasks: true, peerTasks: false, password: lap.password));
      expect(out.error, isNull, reason: '${out.error}');
      expect(out.reply!.otherSide.state, OtherSideState.local);
      AgentInfo agent(String name) => w.agents.firstWhere((a) => a.name == name);
      expect(agent('volna').counterpart, const Counterpart(contact: '', agent: 'reviewer', local: true));
      expect(agent('reviewer').counterpart, const Counterpart(contact: '', agent: 'volna', local: true),
          reason: 'ask (the default): both ways');
      expect(agent('volna').localRoutes, const [LocalRoute(agent: 'reviewer', tasks: true)]);
      expect(agent('reviewer').localRoutes, const [LocalRoute(agent: 'volna')]);
      // The same from the daemon's own agent list, not only the window's copy
      final listed = {for (final a in await l.agents()) a.name: a};
      expect(listed['volna']!.localRoutes, const [LocalRoute(agent: 'reviewer', tasks: true)]);
      g = _graph(w);
      final line = g.edges.where((e) => e.localConnection).single;
      expect((line.local, line.other, line.mutual, line.tasksLocal, line.tasksOther),
          (hereNodeId('volna'), hereNodeId('reviewer'), true, true, false));
      print('LOCAL CONNECT: ${agent('volna').localRoutes} / ${agent('reviewer').localRoutes}');

      // Disconnected from the window with the line's defaults: no password, both ways
      final req = defaultDisconnectFor(g, line)!;
      expect(req.toJson(), {'cmd': 'agent_disconnect', 'name': 'volna', 'local': 'reviewer'});
      final off = await w.disconnectLine(req);
      expect(off.error, isNull, reason: '${off.error}');
      expect(agent('volna').counterpart, isNull);
      expect(agent('reviewer').counterpart, isNull);
      expect(agent('volna').localRoutes, isEmpty);
      expect(agent('reviewer').localRoutes, isEmpty);
      expect(_graph(w).edges.where((e) => e.localConnection), isEmpty);
      print('LOCAL DISCONNECT: the routes are gone both ways');
    } finally {
      m?.dispose();
      await lap.stop();
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 2)));
}
