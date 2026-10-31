// SPDX-License-Identifier: AGPL-3.0-only
// The fake daemon's connections between agents (x-control/7, CONTROL §30): `agent_connect` sets the agent's
// counterpart and task authority here and answers for the other side as the real daemon would (an own computer gets an
// approval request, which shows in its status; a contact decides; a person is a person), `agent_disconnect` clears it,
// `agent_traffic` answers what the test set. Every request is recorded as the exact JSON the window sent. With
// [FakeConnections.connectionsEnabled] off it behaves like a v7 daemon built before connections: its strict parser
// refuses the three commands as an unknown variant. Connections between two agents of this computer (`local`) exist
// only with [FakeConnections.localRoutesEnabled]: every agent's session then has `local_routes`, and without it the
// daemon refuses `local` as an unknown field, as one built before them does.

import 'package:antenna_desktop/protocol/x_control.dart';

import 'fixtures.dart' show contact, fixedNow;

/// The `session` of an agent as `agent_list` gives it.
Map<String, Object?> _sessionJson(Counterpart? counterpart, List<LocalRoute>? localRoutes) => {
      if (counterpart != null)
        'counterpart': {
          'contact': counterpart.contact,
          'agent': ?counterpart.agent,
          if (counterpart.local) 'local': true,
        },
      if (localRoutes != null) 'local_routes': [for (final r in localRoutes) {'agent': r.agent, 'tasks': r.tasks}],
    };

/// An agent of this computer as `agent_list` gives it, with the counterpart and the local connections in its session
/// (the window reads them from the original JSON).
AgentInfo mapAgent(
  String name, {
  Counterpart? counterpart,
  List<String>? tasksFrom,
  bool tasksDefault = false,
  bool alive = false,
  String? localModel,
  List<String>? links,
  List<LocalRoute>? localRoutes,
}) =>
    AgentInfo(
      name: name,
      createdMs: 0,
      localLevel: 3,
      links: links,
      boundPid: alive ? 4242 : null,
      boundComm: alive ? 'claude' : null,
      boundAlive: alive ? true : null,
      tasksFrom: tasksFrom,
      tasksFromDefault: tasksDefault,
      localModel: localModel,
      raw: {'name': name, 'session': _sessionJson(counterpart, localRoutes)},
    );

AgentInfo _withConnection(AgentInfo a,
        {required Counterpart? counterpart,
        required List<String>? tasksFrom,
        bool? tasksDefault,
        List<LocalRoute>? localRoutes}) =>
    AgentInfo(
      name: a.name,
      createdMs: a.createdMs,
      ceiling: a.ceiling,
      links: a.links,
      boundTo: a.boundTo,
      localLevel: a.localLevel,
      everyone: a.everyone,
      boundPid: a.boundPid,
      boundComm: a.boundComm,
      boundAlive: a.boundAlive,
      lastSeenMs: a.lastSeenMs,
      tokenFile: a.tokenFile,
      tasksFrom: tasksFrom,
      tasksFromDefault: tasksDefault ?? a.tasksFromDefault,
      localModel: a.localModel,
      raw: {...a.raw, 'session': _sessionJson(counterpart, localRoutes ?? a.localRoutes)},
    );

/// The demo of the agent map frames and tests: this computer (volna in Claude Code connected both ways with the Mac
/// mini's session-2, docs-bot in Codex connected to Bob's builder and leading the team "site", reviewer waiting for the
/// build server, a local-model agent and the team's worker), the Mac mini and the build server (∞), Bob and Emily
/// Carter with their agents, and recent traffic to Emily's chatgpt.
({List<AgentInfo> agents, List<ContactInfo> contacts, DevicesReply devices, List<TrafficPair> traffic}) mapDemo() {
  final now = fixedNow.millisecondsSinceEpoch;
  return (
    agents: [
      mapAgent('volna',
          counterpart: const Counterpart(contact: 'Mac mini', agent: 'session-2'), tasksFrom: const ['Mac mini'], alive: true),
      mapAgent('docs-bot', counterpart: const Counterpart(contact: 'Bob', agent: 'builder'), tasksFrom: const []),
      mapAgent('reviewer', tasksFrom: const ['Mac mini', 'Build server'], tasksDefault: true),
      mapAgent('helper', localModel: 'qwen3.5-4b'),
    ],
    contacts: [
      contact('Mac mini', 61, trust: 5, peerKind: 'agent', agents: const [PeerAgent(name: 'session-2', state: 'active', sinceMs: 1)]),
      contact('Build server', 62, trust: 5, peerKind: 'agent', agents: const [PeerAgent(name: 'lead', state: 'active', sinceMs: 1)]),
      contact('Bob', 63, trust: 3, peerKind: 'mixed', agents: const [PeerAgent(name: 'builder', state: 'active', sinceMs: 1)]),
      contact('Emily Carter', 64, trust: 3, presence: 'offline', peerKind: 'mixed',
          agents: const [PeerAgent(name: 'chatgpt', state: 'active', sinceMs: 1)]),
    ],
    devices: DevicesReply(
      self: const ThisDevice(name: 'Mayas-MacBook-Pro', os: 'macos', arch: 'aarch64', version: 'antennad 0.2.0'),
      devices: [
        DeviceInfo(
          contact: 'Mac mini',
          linkId: contact('Mac mini', 61).linkId,
          presence: 'online',
          supported: true,
          receivedMs: now,
          status: DeviceView(
            atMs: now,
            name: 'Mac-mini',
            os: 'macos',
            arch: 'aarch64',
            version: 'antennad 0.2.0',
            agents: const [
              DeviceAgent(name: 'session-2', app: 'claude', state: 'connected', counterpart: 'volna', takesTasks: true),
              DeviceAgent(name: 'codex', app: 'codex', state: 'idle'),
            ],
          ),
        ),
        DeviceInfo(
          contact: 'Build server',
          linkId: contact('Build server', 62).linkId,
          presence: 'online',
          supported: true,
          receivedMs: now,
          status: DeviceView(
            atMs: now,
            name: 'ci-01',
            os: 'linux',
            arch: 'x86_64',
            version: 'antennad 0.2.0',
            agents: const [DeviceAgent(name: 'lead', app: 'claude', state: 'idle')],
          ),
        ),
      ],
    ),
    traffic: [
      TrafficPair(agent: 'volna', contact: 'Emily Carter', peerAgent: 'chatgpt', lastMs: now - 2 * 3600000, sent: 3, received: 2),
      TrafficPair(agent: 'volna', contact: 'Mac mini', peerAgent: 'session-2', lastMs: now - 60000, sent: 12, received: 9),
      TrafficPair(agent: '', contact: 'Bob', peerAgent: '', lastMs: now - 86400000, sent: 4, received: 5),
    ],
  );
}

/// What a test sets and reads.
mixin FakeConnections {
  int get protoVersion;
  String get password;

  /// A proof by an enrolled key was checked for the request being carried out (D-131): its password field is empty.
  bool get proofChecked;
  List<ContactInfo> get contactList;
  List<AgentInfo> get agentList;
  set agentList(List<AgentInfo> v);
  DevicesReply get devicesState;
  set devicesState(DevicesReply v);

  /// `false`: a v7 daemon built before connections.
  bool connectionsEnabled = true;

  bool _localRoutes = false;

  /// A daemon that knows connections between two agents of this computer: every agent's session gets `local_routes`
  /// (empty when it has none).
  bool get localRoutesEnabled => _localRoutes;
  set localRoutesEnabled(bool on) {
    _localRoutes = on;
    agentList = [
      for (final a in agentList)
        on
            ? _withConnection(a,
                counterpart: a.counterpart, tasksFrom: a.tasksFrom, localRoutes: a.localRoutes ?? const <LocalRoute>[])
            : _withConnection(a, counterpart: a.counterpart, tasksFrom: a.tasksFrom),
    ];
    if (!on) {
      agentList = [
        for (final a in agentList)
          AgentInfo(
            name: a.name,
            createdMs: a.createdMs,
            localLevel: a.localLevel,
            links: a.links,
            boundPid: a.boundPid,
            boundComm: a.boundComm,
            boundAlive: a.boundAlive,
            tasksFrom: a.tasksFrom,
            tasksFromDefault: a.tasksFromDefault,
            localModel: a.localModel,
            raw: {...a.raw, 'session': _sessionJson(a.counterpart, null)},
          ),
      ];
    }
  }

  /// Every `agent_connect` / `agent_disconnect` as the exact JSON the window sent (the password included: the test
  /// checks it went to the daemon).
  final connectCalls = <Map<String, Object?>>[];
  final disconnectCalls = <Map<String, Object?>>[];
  int trafficCalls = 0;
  List<TrafficPair> trafficPairs = [];

  /// What the other side answers, per contact; otherwise as the real daemon decides.
  final otherSideFor = <String, OtherSide>{};

  /// The next connect fails with this error (the daemon refused the command itself).
  XControlException? connectRefusal;

  /// The next disconnect fails with this error.
  XControlException? disconnectRefusal;

  /// A disconnect waits for this before it answers (a test sees the line while it runs).
  Future<void>? disconnectGate;
  var _ids = 0;

  bool _own(String contact) =>
      devicesState.devices.any((d) => d.contact == contact) || contactList.any((c) => c.label == contact && c.trust >= 5);

  /// The other computer's request, as its next status would list it.
  String _ask(String device, {required String agent, required String? peer, required bool? tasks}) {
    final id = 'cn${(++_ids).toString().padLeft(6, '0')}';
    final now = fixedNow.millisecondsSinceEpoch;
    final me = devicesState.self.name;
    devicesState = DevicesReply(self: devicesState.self, devices: [
      for (final d in devicesState.devices)
        if (d.contact != device || d.status == null)
          d
        else
          DeviceInfo(
            contact: d.contact,
            linkId: d.linkId,
            presence: d.presence,
            supported: d.supported,
            receivedMs: d.receivedMs,
            confirmed: d.confirmed,
            offered: d.offered,
            acceptsMine: d.acceptsMine,
            lostBy: d.lostBy,
            status: DeviceView(
              atMs: d.status!.atMs,
              name: d.status!.name,
              os: d.status!.os,
              arch: d.status!.arch,
              version: d.status!.version,
              agents: d.status!.agents,
              approvals: [
                ...d.status!.approvals,
                DeviceApproval(
                  id: id,
                  action: peer == null ? 'disconnect_agent' : 'connect_agent',
                  requester: me,
                  contact: me,
                  contactTrust: 5,
                  reasons: const ['agent_connect'],
                  quote: peer == null
                      ? 'Disconnect $agent from $me: its messages without an address no longer go there.'
                      : 'Connect $agent with $peer on $me: messages from $agent without an address go to $peer.'
                          '${tasks == true ? ' Messages from $me become tasks for $agent.' : ''}',
                  fingerprint: '5c0nn3c7${id.padLeft(8, '0')}',
                  createdMs: now,
                  expiresMs: now + 600000,
                  completes: true,
                ),
              ],
              pendingApprovals: d.status!.pendingApprovals + 1,
              lend: d.status!.lend,
            ),
          ),
    ]);
    return id;
  }

  AgentInfo _agent(String name) => agentList.firstWhere((a) => a.name == name,
      orElse: () => throw XControlException(XErrorCode.notFound, 'no agent $name'));

  void _put(AgentInfo a) => agentList = [for (final x in agentList) x.name == a.name ? a : x];

  List<String> _tasks(AgentInfo a, String contact, bool? tasks) {
    final now = a.tasksFrom ?? const <String>[];
    return switch (tasks) {
      true => [...now.where((c) => c != contact), contact],
      false => [for (final c in now) if (c != contact) c],
      null => now,
    };
  }

  /// The connection commands of [FakeDaemon.call].
  Future<Reply> connectionsCall(ConnectionRequest r) async {
    if (protoVersion < 7 || !connectionsEnabled) {
      throw XControlException(XErrorCode.badRequest,
          'bad message: unknown variant `${r.cmd}`, expected one of `status`, `init`, `unlock`');
    }
    switch (r) {
      case AgentTrafficRequest():
        trafficCalls++;
        return AgentTrafficReply(sinceMs: 0, pairs: trafficPairs);
      case LocalConnectRequest():
        connectCalls.add(r.toJson());
        if (!_localRoutes) {
          throw const XControlException(
              XErrorCode.badRequest, 'bad message: unknown field `local`, expected one of `name`, `contact`, `agent`');
        }
        if (r.password != password) throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
        if (connectRefusal case final e?) {
          connectRefusal = null;
          throw e;
        }
        final a = _agent(r.name);
        final b = _agent(r.local);
        if (a.name == b.name) throw const XControlException(XErrorCode.badRequest, 'an agent cannot connect to itself');
        if (a.localModel != null || b.localModel != null) {
          throw const XControlException(XErrorCode.denied, 'a local-model agent answers only its own conversation');
        }
        List<LocalRoute> route(AgentInfo x, String to, bool tasks) =>
            [...?x.localRoutes?.where((y) => y.agent != to), LocalRoute(agent: to, tasks: tasks)];
        final a2 = _withConnection(a,
            counterpart: Counterpart(contact: '', agent: b.name, local: true),
            tasksFrom: a.tasksFrom,
            localRoutes: route(a, b.name, r.tasks ?? false));
        final b2 = _withConnection(b,
            counterpart: r.ask ? Counterpart(contact: '', agent: a.name, local: true) : b.counterpart,
            tasksFrom: b.tasksFrom,
            localRoutes: route(b, a.name, r.peerTasks ?? false));
        _put(a2);
        _put(b2);
        return AgentConnectedReply(
            agent: a2, otherSide: OtherSide(state: r.ask ? OtherSideState.local : OtherSideState.notAsked));
      case LocalDisconnectRequest():
        disconnectCalls.add(r.toJson());
        if (disconnectGate case final g?) await g;
        if (!_localRoutes) {
          throw const XControlException(
              XErrorCode.badRequest, 'bad message: unknown field `local`, expected one of `name`, `contact`, `agent`');
        }
        if (disconnectRefusal case final e?) {
          disconnectRefusal = null;
          throw e;
        }
        final a = _agent(r.name);
        final b = _agent(r.local);
        AgentInfo off(AgentInfo x, String other) {
          final cp = x.counterpart;
          return _withConnection(x,
              counterpart: cp != null && cp.local && cp.agent == other ? null : cp,
              tasksFrom: x.tasksFrom,
              localRoutes: [...?x.localRoutes?.where((y) => y.agent != other)]);
        }

        final a2 = off(a, b.name);
        _put(a2);
        _put(off(b, a.name));
        return AgentConnectedReply(agent: a2, otherSide: const OtherSide(state: OtherSideState.local));
      case AgentConnectRequest():
        connectCalls.add(r.toJson());
        if (!proofChecked && r.password != password) {
          throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
        }
        if (connectRefusal case final e?) {
          connectRefusal = null;
          throw e;
        }
        final a = _agent(r.name);
        if (!contactList.any((c) => c.label == r.contact)) {
          throw XControlException(XErrorCode.notFound, 'no contact ${r.contact}');
        }
        final changed = r.tasks != null;
        final now = _withConnection(a,
            counterpart: Counterpart(contact: r.contact, agent: r.agent),
            tasksFrom: _tasks(a, r.contact, r.tasks),
            tasksDefault: changed ? false : null);
        _put(now);
        final OtherSide side;
        if (otherSideFor[r.contact] case final s?) {
          side = s;
        } else if (r.agent == null) {
          side = const OtherSide(state: OtherSideState.person);
        } else if (!_own(r.contact)) {
          side = const OtherSide(state: OtherSideState.contactDecides);
        } else if (!r.ask) {
          side = const OtherSide(state: OtherSideState.notAsked);
        } else {
          side = OtherSide(
              state: OtherSideState.requested,
              id: _ask(r.contact, agent: r.agent!, peer: r.name, tasks: r.peerTasks));
        }
        return AgentConnectedReply(agent: now, otherSide: side);
      case AgentDisconnectRequest():
        disconnectCalls.add(r.toJson());
        if (disconnectGate case final g?) await g;
        if (disconnectRefusal case final e?) {
          disconnectRefusal = null;
          throw e;
        }
        final a = _agent(r.name);
        final cp = a.counterpart;
        final contact = r.contact ?? cp?.contact;
        if (contact == null) throw const XControlException(XErrorCode.badRequest, 'this agent has no default counterpart');
        final clears = r.contact == null || (cp?.contact == r.contact && cp?.agent == r.agent);
        final now = _withConnection(a,
            counterpart: clears ? null : cp,
            tasksFrom: _tasks(a, contact, r.tasks == false ? false : null),
            tasksDefault: r.tasks == false ? false : null);
        _put(now);
        final peer = r.agent ?? (r.contact == null ? cp?.agent : null);
        final OtherSide side;
        if (otherSideFor[contact] case final s?) {
          side = s;
        } else if (peer == null) {
          side = const OtherSide(state: OtherSideState.person);
        } else if (!_own(contact)) {
          side = const OtherSide(state: OtherSideState.contactDecides);
        } else if (!r.ask) {
          side = const OtherSide(state: OtherSideState.notAsked);
        } else {
          side = OtherSide(state: OtherSideState.requested, id: _ask(contact, agent: peer, peer: null, tasks: r.peerTasks));
        }
        return AgentConnectedReply(agent: now, otherSide: side);
    }
  }
}
