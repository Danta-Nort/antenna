// SPDX-License-Identifier: AGPL-3.0-only
// The agent map's graph and geometry, pure (state/agent_map.dart, ui/agents/agent_map_layout.dart): clusters from the
// agents, own devices and contacts; configured, mutual, waiting, traffic and team lines; traffic hidden under a line
// that is set; the kinds a line cannot reach; what a drop means; the requests a line sends (no choice ever goes to a
// contact's side, a checkbox that changes nothing is not sent, disconnecting carries no password); a deterministic
// layout in three columns where no line crosses a group and a line between two agents of one group stays inside it;
// own computers always on the left (the placement fix of D-UI-47); the owner's arrangement; local connections; what
// Disconnect on a selected line sends.

import 'dart:ui' show Offset, Rect;

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_map.dart';
import 'package:antenna_desktop/ui/agents/agent_map_layout.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connections.dart';
import '../support/fake_teams.dart';
import '../support/fixtures.dart';

final _site = TeamInfo(
  name: 'site',
  project: '/Users/maya/code/site',
  target: 'main',
  integration: 'antenna/site',
  lead: 'docs-bot',
  state: 'active',
  workers: [
    demoWorker('site.docs-1', team: 'site', kind: WorkerKind.local, state: WorkerState.busy),
    demoWorker('site.docs-2', team: 'site', kind: WorkerKind.local, state: WorkerState.stopped),
  ],
);

AgentMapGraph _graph({
  List<AgentInfo>? agents,
  DevicesReply? devices,
  List<TrafficPair>? traffic,
  List<PendingConnect> pending = const [],
  Set<String> wake = const {},
  List<TeamInfo>? teams,
}) {
  final d = mapDemo();
  return buildAgentMap(
    agents: agents ?? d.agents,
    wakeAgents: wake,
    teams: teams ?? [_site],
    thisName: (devices ?? d.devices).self.name,
    devices: (devices ?? d.devices).devices,
    contacts: d.contacts,
    traffic: traffic ?? d.traffic,
    pending: pending,
  );
}

MapEdge? _line(AgentMapGraph g, MapEdgeKind k, String local, String other) =>
    g.edges.where((e) => e.kind == k && e.local == local && e.other == other).firstOrNull;

DevicesReply _withApproval(DevicesReply r, String device, String id) => DevicesReply(self: r.self, devices: [
      for (final d in r.devices)
        d.contact != device
            ? d
            : DeviceInfo(
                contact: d.contact,
                linkId: d.linkId,
                presence: d.presence,
                supported: d.supported,
                status: DeviceView(
                  atMs: 0,
                  name: d.status!.name,
                  os: d.status!.os,
                  arch: d.status!.arch,
                  version: d.status!.version,
                  agents: d.status!.agents,
                  approvals: [
                    DeviceApproval(
                        id: id, action: 'connect_agent', requester: 'MacBook', contact: 'MacBook', fingerprint: 'f',
                        createdMs: 0, expiresMs: 1, reasons: const ['agent_connect']),
                  ],
                  pendingApprovals: 1,
                ),
              ),
    ]);

void main() {
  test('clusters: this computer first, the own computers, then the contacts with their person', () {
    final g = _graph(wake: {'reviewer'});
    expect([for (final c in g.clusters) (c.kind, c.title)], [
      (MapClusterKind.here, 'Mayas-MacBook-Pro'),
      (MapClusterKind.ownComputer, 'Mac mini'),
      (MapClusterKind.ownComputer, 'Build server'),
      (MapClusterKind.contact, 'Bob'),
      (MapClusterKind.contact, 'Emily Carter'),
    ]);
    // A lead is followed by its team's workers; then the wake agents and the local-model agents; a stopped worker is
    // not drawn.
    expect([for (final n in g.clusters.first.nodes) n.name], ['volna', 'docs-bot', 'site.docs-1', 'reviewer', 'helper']);
    final here = {for (final n in g.clusters.first.nodes) n.name: n};
    expect(here['volna']!.connectable, isTrue);
    expect(here['volna']!.live, isTrue, reason: 'its token is bound to a live process');
    expect(here['site.docs-1']!.notConnectable, MapNotConnectable.worker);
    expect(here['site.docs-1']!.team, 'site');
    expect(here['reviewer']!.notConnectable, MapNotConnectable.wake);
    expect(here['helper']!.notConnectable, MapNotConnectable.localModel);
    final mini = g.cluster('c/Mac mini')!;
    expect([for (final n in mini.nodes) (n.name, n.kind, n.app, n.live)], [
      ('session-2', MapNodeKind.device, 'claude', true),
      ('codex', MapNodeKind.device, 'codex', false),
    ]);
    expect(mini.nodes.any((n) => n.person), isFalse, reason: 'an own computer has no person node');
    final bob = g.cluster('c/Bob')!;
    expect([for (final n in bob.nodes) (n.name, n.kind)], [('Bob', MapNodeKind.person), ('builder', MapNodeKind.contactAgent)]);
    expect(g.cluster('c/Emily Carter')!.nodes.first.live, isFalse, reason: 'offline');
  });

  test('lines that are set: both ways once, one way, the tasks marks at each end', () {
    final g = _graph();
    final mutual = _line(g, MapEdgeKind.configured, 'here/volna', 'c/Mac mini/a/session-2')!;
    expect((mutual.toOther, mutual.toLocal, mutual.mutual), (true, true, true));
    expect((mutual.tasksLocal, mutual.tasksOther), (true, true), reason: 'volna takes Mac mini\'s tasks; session-2 ours');
    expect(g.edges.where((e) => e.other == 'c/Mac mini/a/session-2' && e.kind == MapEdgeKind.configured), hasLength(1));
    final oneWay = _line(g, MapEdgeKind.configured, 'here/docs-bot', 'c/Bob/a/builder')!;
    expect((oneWay.toOther, oneWay.toLocal, oneWay.tasksLocal, oneWay.tasksOther), (true, false, false, false));
    // A line only the other side drew: the Mac mini's codex points at reviewer
    final d = mapDemo().devices;
    final other = DevicesReply(self: d.self, devices: [
      DeviceInfo(
        contact: 'Mac mini',
        linkId: d.devices.first.linkId,
        presence: 'online',
        supported: true,
        status: const DeviceView(atMs: 0, name: 'm', os: 'macos', arch: 'a', version: 'v', agents: [
          DeviceAgent(name: 'codex', state: 'idle', counterpart: 'reviewer'),
          DeviceAgent(name: 'helper', state: 'local', app: 'local', counterpart: ''),
        ]),
      ),
    ]);
    final g2 = _graph(devices: other);
    final there = _line(g2, MapEdgeKind.configured, 'here/reviewer', 'c/Mac mini/a/codex')!;
    expect((there.toOther, there.toLocal, there.tasksLocal), (false, true, true));
    // An agent there whose counterpart is this computer's person: the owner's own node appears, not connectable
    final you = g2.node(youNodeId)!;
    expect((you.kind, you.notConnectable), (MapNodeKind.you, MapNotConnectable.you));
    expect(_line(g2, MapEdgeKind.configured, youNodeId, 'c/Mac mini/a/helper')!.toLocal, isTrue);
    expect(g2.node('c/Mac mini/a/helper')!.notConnectable, MapNotConnectable.remoteLocalModel);
    expect(g.node(youNodeId), isNull, reason: 'only when a line points at the owner');
  });

  test('waiting: while the request this window made is pending on that computer', () {
    final agents = [
      ...mapDemo().agents.where((a) => a.name != 'reviewer'),
      mapAgent('reviewer', counterpart: const Counterpart(contact: 'Build server', agent: 'lead')),
    ];
    const pending = [PendingConnect(id: 'cn000001', contact: 'Build server', agent: 'reviewer', peerAgent: 'lead')];
    final waiting = _graph(agents: agents, pending: pending, devices: _withApproval(mapDemo().devices, 'Build server', 'cn000001'));
    final e = _line(waiting, MapEdgeKind.waiting, 'here/reviewer', 'c/Build server/a/lead')!;
    expect((e.waitingOn, e.requestId, e.toOther), ('Build server', 'cn000001', true));
    expect(_line(waiting, MapEdgeKind.configured, 'here/reviewer', 'c/Build server/a/lead'), isNull);
    // Answered there (no longer in its status): the line is just set
    final answered = _graph(agents: agents, pending: pending);
    expect(_line(answered, MapEdgeKind.waiting, 'here/reviewer', 'c/Build server/a/lead'), isNull);
    expect(_line(answered, MapEdgeKind.configured, 'here/reviewer', 'c/Build server/a/lead'), isNotNull);
  });

  test('traffic: a line where none is set, hidden under one that is, never for the owner in person', () {
    final g = _graph(traffic: [
      ...mapDemo().traffic,
      const TrafficPair(agent: 'docs-bot', contact: 'Emily Carter', peerAgent: 'writer', lastMs: 5, sent: 1, received: 0),
    ]);
    final t = _line(g, MapEdgeKind.traffic, 'here/volna', 'c/Emily Carter/a/chatgpt')!;
    expect((t.lastMs, t.sent, t.received), (fixedNow.millisecondsSinceEpoch - 2 * 3600000, 3, 2));
    expect(_line(g, MapEdgeKind.traffic, 'here/volna', 'c/Mac mini/a/session-2'), isNull,
        reason: 'a configured line hides the traffic of the same pair');
    expect(g.edges.where((e) => e.kind == MapEdgeKind.traffic && e.other == 'c/Bob/p'), isEmpty,
        reason: 'the owner\'s own messages are not a line');
    // An agent the contact did not announce, but that wrote: added to its cluster
    expect(g.node('c/Emily Carter/a/writer')!.kind, MapNodeKind.contactAgent);
    expect(_line(g, MapEdgeKind.traffic, 'here/docs-bot', 'c/Emily Carter/a/writer'), isNotNull);
    // Painting order: traffic and team first, the lines that are set on top
    final kinds = [for (final e in g.edges) e.kind];
    expect(kinds.indexOf(MapEdgeKind.configured), greaterThan(kinds.lastIndexOf(MapEdgeKind.traffic)));
  });

  test('team lines: the lead to each worker that is not stopped', () {
    final g = _graph();
    final team = [for (final e in g.edges) if (e.kind == MapEdgeKind.team) (e.local, e.other, e.team)];
    expect(team, [('here/docs-bot', 'here/site.docs-1', 'site')]);
    expect(_graph(teams: const []).edges.where((e) => e.kind == MapEdgeKind.team), isEmpty);
  });

  test('drops: one end on this computer, the other on another; the kinds the daemon refuses send nothing', () {
    final g = _graph(wake: {'reviewer'});
    expect(checkDrop(g, 'here/volna', 'here/volna'), isNull);
    expect((checkDrop(g, 'here/volna', 'here/docs-bot')! as DropNote).problem, DropProblem.localUnsupported);
    expect((checkDrop(g, 'c/Bob/a/builder', 'c/Mac mini/a/codex')! as DropNote).problem, DropProblem.noLocal);
    for (final (name, why) in [
      ('reviewer', MapNotConnectable.wake),
      ('site.docs-1', MapNotConnectable.worker),
      ('helper', MapNotConnectable.localModel),
    ]) {
      final n = checkDrop(g, 'here/$name', 'c/Bob/a/builder')! as DropNote;
      expect((n.problem, n.node?.notConnectable), (DropProblem.notConnectable, why), reason: name);
    }
    final ok = checkDrop(g, 'c/Mac mini/a/codex', 'here/volna')! as DropConnect;
    expect((ok.local.name, ok.other.name), ('volna', 'codex'), reason: 'a line drawn from the other end too');
    final person = checkDrop(g, 'here/docs-bot', 'c/Emily Carter/p')! as DropConnect;
    expect(person.other.person, isTrue);
  });

  test('connect: peer tasks only for an own computer\'s agent, tasks only when they change', () {
    final g = _graph();
    final volna = g.node('here/volna')!;
    final own = connectRequestFor(
        local: volna, other: g.node('c/Mac mini/a/codex')!, own: true, tasks: true, currentTasks: false, peerTasks: true,
        password: 'pw');
    expect(own.toJson(), {
      'cmd': 'agent_connect',
      'name': 'volna',
      'contact': 'Mac mini',
      'agent': 'codex',
      'tasks': true,
      'peer_tasks': true,
      'password': 'pw',
    });
    final contact = connectRequestFor(
        local: volna, other: g.node('c/Bob/a/builder')!, own: false, tasks: true, currentTasks: false, peerTasks: true,
        password: 'pw');
    expect(contact.toJson().containsKey('peer_tasks'), isFalse, reason: 'a contact\'s side is the contact\'s decision');
    expect(contact.toJson()['tasks'], isTrue);
    final person = connectRequestFor(
        local: volna, other: g.node('c/Bob/p')!, own: false, tasks: false, currentTasks: false, peerTasks: true,
        password: 'pw');
    expect(person.toJson(), {'cmd': 'agent_connect', 'name': 'volna', 'contact': 'Bob', 'password': 'pw'});
    final same = connectRequestFor(
        local: volna, other: g.node('c/Mac mini/a/codex')!, own: true, tasks: true, currentTasks: true, peerTasks: false,
        password: 'pw');
    expect(same.toJson().containsKey('tasks'), isFalse, reason: 'unchanged: a default list stays the default');
    expect(same.toJson()['peer_tasks'], isFalse);
  });

  test('disconnect: no password; asking and the other side\'s tasks only for an own computer', () {
    final own = disconnectRequestFor(agent: 'volna', contact: 'Mac mini', peerAgent: 'session-2', own: true);
    expect(own.toJson(), {'cmd': 'agent_disconnect', 'name': 'volna', 'contact': 'Mac mini', 'agent': 'session-2'});
    expect(
        disconnectRequestFor(
                agent: 'volna', contact: 'Mac mini', peerAgent: 'session-2', own: true, stopTasks: true, peerStopTasks: true)
            .toJson(),
        {'cmd': 'agent_disconnect', 'name': 'volna', 'contact': 'Mac mini', 'agent': 'session-2', 'tasks': false, 'peer_tasks': false});
    expect(
        disconnectRequestFor(
                agent: 'volna', contact: 'Mac mini', peerAgent: 'session-2', own: true, ask: false, peerStopTasks: true)
            .toJson(),
        {'cmd': 'agent_disconnect', 'name': 'volna', 'contact': 'Mac mini', 'agent': 'session-2', 'ask': false},
        reason: 'not asking: nothing for the other side');
    final contact =
        disconnectRequestFor(agent: 'docs-bot', contact: 'Bob', peerAgent: 'builder', own: false, ask: false, peerStopTasks: true);
    expect(contact.toJson(), {'cmd': 'agent_disconnect', 'name': 'docs-bot', 'contact': 'Bob', 'agent': 'builder'});
    for (final r in [own, contact]) {
      expect(r.toJson().containsKey('password'), isFalse);
    }
  });

  test('layout: deterministic, three columns, no line crosses a group, lines inside a group stay in its lane', () {
    final g = _graph(traffic: [
      ...mapDemo().traffic,
      const TrafficPair(agent: 'volna', contact: '', peerAgent: 'reviewer', local: true, lastMs: 5, sent: 2, received: 1),
    ]);
    final a = layoutAgentMap(g);
    final b = layoutAgentMap(g);
    expect(a.nodes, b.nodes, reason: 'the same facts give the same picture');
    final here = a.clusters['here']!;
    expect(a.clusters['c/Mac mini']!.right, lessThan(here.left));
    expect(a.clusters['c/Build server']!.right, lessThan(here.left));
    expect(a.clusters['c/Bob']!.left, greaterThan(here.right));
    expect(a.clusters['c/Emily Carter']!.left, greaterThan(here.right));
    expect(a.lanes.keys, ['here'], reason: 'this computer has lines between its own agents (the team, recent messages)');
    for (final l in a.lines) {
      final ends = {g.node(l.edge.local)!.cluster, g.node(l.edge.other)!.cluster};
      for (var i = 0; i <= 32; i++) {
        final p = l.at(i / 32);
        if (ends.length == 1) {
          // Inside one group: in its lane, never leaving it, never over a card.
          expect(a.clusters[ends.first]!.contains(p), isTrue, reason: '${l.edge.key} leaves its group');
          if (i > 0 && i < 32) {
            for (final n in a.nodes.values) {
              expect(n.deflate(1).contains(p), isFalse, reason: '${l.edge.key} over a card');
            }
          }
          continue;
        }
        // Between groups: never through a third one.
        for (final c in a.clusters.entries) {
          if (ends.contains(c.key)) continue;
          expect(c.value.deflate(1).contains(p), isFalse, reason: '${l.edge.key} crosses ${c.key}');
        }
      }
    }
    // A line is found where it is drawn, of any kind
    final team = a.lines.firstWhere((l) => l.edge.kind == MapEdgeKind.team);
    expect(a.lineAt(team.at(0.4))?.edge.key, team.edge.key);
    expect(a.lineAt(here.topLeft - const Offset(40, 40)), isNull);
  });

  test('placement: own computers always on the left, contacts on the right, whatever the counts', () {
    double x(MapLayout l, String id) => l.clusters[id]!.center.dx;
    final server = contact('hel server', 71, trust: 5, peerKind: 'agent');
    final agents = [mapAgent('claude-code', alive: true)];
    // The maintainer's case: the only other computer is an own one, and it has not reported itself yet
    final missing = buildAgentMap(agents: agents, contacts: [server], devices: [
      DeviceInfo(contact: 'hel server', linkId: server.linkId, presence: 'online', supported: true),
    ]);
    final c = missing.cluster('c/hel server')!;
    expect((c.kind, c.reportMissing, c.online), (MapClusterKind.ownComputer, true, true));
    expect(x(layoutAgentMap(missing), 'c/hel server'), lessThan(x(layoutAgentMap(missing), 'here')));
    // Not in `devices` at all (an older daemon, devices refused or not read yet): still an own computer, on the left
    final noDevices = buildAgentMap(agents: agents, contacts: [server]);
    expect(noDevices.cluster('c/hel server')!.kind, MapClusterKind.ownComputer);
    expect(noDevices.cluster('c/hel server')!.reportMissing, isTrue);
    expect(x(layoutAgentMap(noDevices), 'c/hel server'), lessThan(x(layoutAgentMap(noDevices), 'here')));
    // Reported: no note
    final reported = buildAgentMap(agents: agents, contacts: [server], devices: [
      DeviceInfo(
          contact: 'hel server',
          linkId: server.linkId,
          presence: 'online',
          supported: true,
          status: const DeviceView(atMs: 0, name: 'hel', os: 'linux', arch: 'x86_64', version: 'v', agents: [])),
    ]);
    expect(reported.cluster('c/hel server')!.reportMissing, isFalse);
    // Several own computers and no contact: all on the left; only contacts: all on the right
    final two = buildAgentMap(agents: agents, contacts: [server, contact('Mac mini', 61, trust: 5)]);
    final l2 = layoutAgentMap(two);
    expect([x(l2, 'c/hel server'), x(l2, 'c/Mac mini')], everyElement(lessThan(x(l2, 'here'))));
    final people = buildAgentMap(agents: agents, contacts: mapDemo().contacts.where((c) => c.trust < 5).toList());
    final lp = layoutAgentMap(people);
    expect([x(lp, 'c/Bob'), x(lp, 'c/Emily Carter')], everyElement(greaterThan(x(lp, 'here'))));
    // A contact at level 4 is a contact, even with `devices` listing nothing
    final four = buildAgentMap(agents: agents, contacts: [contact('Bob', 63, trust: 4)], devices: const []);
    expect(four.cluster('c/Bob')!.kind, MapClusterKind.contact);
    expect(four.cluster('c/Bob')!.reportMissing, isFalse);
  });

  test('the arrangement: saved places and orders, new groups below, gone ones ignored, a card being moved', () {
    final g = _graph();
    final auto = layoutAgentMap(g);
    final moved = layoutAgentMap(g, positions: {
      'c/Mac mini': const Offset(-500, 900),
      'c/Gone': const Offset(10, 10),
    }, order: {
      'here': ['here/helper', 'here/gone', 'here/volna'],
      'c/Gone': ['x'],
    });
    expect(moved.clusters['c/Mac mini']!.topLeft, const Offset(-500, 900));
    expect(moved.clusters.containsKey('c/Gone'), isFalse);
    expect(moved.clusters['c/Bob'], auto.clusters['c/Bob'], reason: 'a group the arrangement does not know: automatic');
    expect(moved.slots['here'], ['here/helper', 'here/volna', 'here/docs-bot', 'here/site.docs-1', 'here/reviewer'],
        reason: 'the saved order first, gone cards dropped, new ones after it');
    expect(moved.nodes['here/helper']!.top, lessThan(moved.nodes['here/volna']!.top));
    expect(moved.bounds.contains(const Offset(-500, 900)), isTrue);
    // A new group is placed in its column below what is already there
    final crowded = layoutAgentMap(g, positions: {'here': auto.clusters['c/Bob']!.topLeft});
    final bob = crowded.clusters['c/Bob']!;
    expect(bob.overlaps(crowded.clusters['here']!), isFalse);
    // A card being dragged: the others make room, its lines follow where it is drawn
    final drag = layoutAgentMap(g, move: (node: 'here/volna', slot: 2), floating: (
      node: 'here/volna',
      rect: const Rect.fromLTWH(2000, 2000, 240, 48),
    ));
    expect(drag.slots['here'], ['here/docs-bot', 'here/site.docs-1', 'here/volna', 'here/reviewer', 'here/helper']);
    final line = drag.lines.firstWhere((l) => l.edge.key == 'configured:here/volna>c/Mac mini/a/session-2');
    expect(line.p0.dy, 2024);
    expect(drag.slotAt('here', drag.clusters['here']!.top + MapMetrics.slotTop(4)), 4);
    expect(drag.slotAt('here', -1e6), 0);
    expect(drag.slotAt('here', 1e6), 4);
  });

  test('local connections: one line per pair from local_routes, arrows from the counterparts, tasks at each end', () {
    final agents = [
      mapAgent('volna',
          counterpart: const Counterpart(contact: '', agent: 'reviewer', local: true),
          tasksFrom: const ['Mac mini'],
          localRoutes: const [LocalRoute(agent: 'reviewer', tasks: true)]),
      mapAgent('docs-bot', localRoutes: const []),
      mapAgent('reviewer', localRoutes: const [LocalRoute(agent: 'volna')]),
      mapAgent('helper', localModel: 'qwen3.5-4b', localRoutes: const []),
    ];
    final g = _graph(agents: agents, traffic: const [
      TrafficPair(agent: 'reviewer', contact: '', peerAgent: 'volna', local: true, lastMs: 9, sent: 1, received: 1),
      TrafficPair(agent: 'docs-bot', contact: '', peerAgent: 'volna', local: true, lastMs: 8, sent: 4, received: 0),
      TrafficPair(agent: 'volna', contact: '', peerAgent: 'docs-bot', local: true, lastMs: 7, sent: 0, received: 4),
    ]);
    final l = _line(g, MapEdgeKind.configured, 'here/volna', 'here/reviewer')!;
    expect((l.inside, l.localConnection, l.toOther, l.toLocal, l.tasksLocal, l.tasksOther),
        (true, true, true, false, true, false));
    expect(g.edges.where((e) => e.inside && e.kind == MapEdgeKind.configured), hasLength(1), reason: 'one line per pair');
    expect(_line(g, MapEdgeKind.configured, 'here/volna', 'c/Mac mini/a/session-2')?.toOther, isNot(isTrue),
        reason: 'a local counterpart is not a remote one');
    // Recent messages inside: only where nothing is set, one line per pair whichever way it is listed
    expect(g.edges.where((e) => e.kind == MapEdgeKind.traffic && e.inside), hasLength(1));
    final t = g.edges.singleWhere((e) => e.kind == MapEdgeKind.traffic && e.inside);
    expect({t.local, t.other}, {'here/docs-bot', 'here/volna'});
    // The drops
    expect(checkDrop(g, 'here/volna', 'here/docs-bot', localRoutes: true), isA<DropConnectLocal>());
    expect((checkDrop(g, 'here/volna', 'here/docs-bot')! as DropNote).problem, DropProblem.localUnsupported);
    final model = checkDrop(g, 'here/volna', 'here/helper', localRoutes: true)! as DropNote;
    expect((model.problem, model.node?.name), (DropProblem.notConnectable, 'helper'));
    final worker = checkDrop(g, 'here/site.docs-1', 'here/volna', localRoutes: true)! as DropNote;
    expect(worker.node?.notConnectable, MapNotConnectable.worker);
  });

  test('Disconnect on a selected line: the dialog\'s defaults, no password; nothing for history, a team or a line to you',
      () {
    final g = _graph(agents: [
      ...mapDemo().agents.where((a) => a.name != 'reviewer'),
      mapAgent('reviewer',
          counterpart: const Counterpart(contact: '', agent: 'volna', local: true),
          localRoutes: const [LocalRoute(agent: 'volna')]),
    ]);
    ConnectionRequest? off(String key) => defaultDisconnectFor(g, g.edges.firstWhere((e) => e.key == key));
    expect(off('configured:here/volna>c/Mac mini/a/session-2')!.toJson(),
        {'cmd': 'agent_disconnect', 'name': 'volna', 'contact': 'Mac mini', 'agent': 'session-2'});
    expect(off('configured:here/docs-bot>c/Bob/a/builder')!.toJson(),
        {'cmd': 'agent_disconnect', 'name': 'docs-bot', 'contact': 'Bob', 'agent': 'builder'});
    expect(off('configured:here/reviewer>here/volna')!.toJson(),
        {'cmd': 'agent_disconnect', 'name': 'reviewer', 'local': 'volna'});
    expect(off('traffic:here/volna>c/Emily Carter/a/chatgpt'), isNull);
    expect(off('team:here/docs-bot>here/site.docs-1'), isNull);
    for (final e in g.edges) {
      expect(defaultDisconnectFor(g, e)?.toJson().containsKey('password') ?? false, isFalse);
    }
    // A line another own computer drew to the owner in person: set there, nothing to send from here
    final d = mapDemo().devices;
    final there = DevicesReply(self: d.self, devices: [
      DeviceInfo(
        contact: 'Mac mini',
        linkId: d.devices.first.linkId,
        presence: 'online',
        supported: true,
        status: const DeviceView(
            atMs: 0, name: 'm', os: 'macos', arch: 'a', version: 'v', agents: [DeviceAgent(name: 'codex', counterpart: '', state: 'idle')]),
      ),
    ]);
    final g2 = _graph(devices: there);
    final you = g2.edges.firstWhere((e) => e.local == youNodeId);
    expect(defaultDisconnectFor(g2, you), isNull);
  });
}
