// SPDX-License-Identifier: AGPL-3.0-only
// The agent map (x-control/7, CONTROL §30, D-123; experimental): this computer's agents, the owner's other
// computers and the contacts as clusters, and the lines between them. A line the owner draws is an agent's default
// counterpart (where its messages without an address go); whose messages it takes as tasks is the task authority of
// D-88. The daemon sets both and decides everything; on an own computer the other side is an approval request there.
//
// The window owns none of it: the graph is derived from `agent_list` (`session.counterpart`, `tasks_from`), `devices`
// (`status.agents[].counterpart`, `takes_tasks`, the requests waiting there), `contacts`, the teams and
// `agent_traffic`, every time it is drawn. The only thing the window keeps is the ID of a request its own
// `agent_connect` made on another own computer, so the line can say it waits for that request while the request is
// still pending there (the daemon of that computer is the one that knows). An older daemon has no connections: the map
// still shows the agents and says connecting needs a newer Antenna. Two agents of this computer can be connected when
// the daemon sends `session.local_routes` (D-UI-47): both sides are set here, so nothing waits on another computer.
// How the owner arranged the map is the window's own (agent_map_prefs.dart), never in here.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'agent_map_graph.dart';
import 'owner_auth.dart';

export 'agent_map_graph.dart';

/// The Agents page: the list (cards) or the map. Kept while the window runs.
enum AgentsView { list, map }

/// Why a drop connects nothing; the screen says it in words.
enum DropProblem {
  /// Both ends are agents of this computer, and its daemon does not know local connections (no `local_routes`).
  localUnsupported,

  /// Neither end is on this computer.
  noLocal,

  /// One end is a wake agent, a worker, a local-model agent or the owner in person ([DropNote.node]).
  notConnectable,
}

sealed class DropResult {
  const DropResult();
}

/// A line the daemon can set: [local] (an agent of this computer) to [other] (an agent or a person of another one).
final class DropConnect extends DropResult {
  const DropConnect(this.local, this.other);
  final MapNode local;
  final MapNode other;
}

/// A connection between two agents of this computer: [from] (where the line started) and [to].
final class DropConnectLocal extends DropResult {
  const DropConnectLocal(this.from, this.to);
  final MapNode from;
  final MapNode to;
}

/// A drop that sends nothing, and why.
final class DropNote extends DropResult {
  const DropNote(this.problem, [this.node]);
  final DropProblem problem;
  final MapNode? node;
}

/// What a line drawn from [from] to [to] would be; `null` for a drop on the node it started from. [localRoutes]: the
/// daemon knows connections between two agents of this computer.
DropResult? checkDrop(AgentMapGraph g, String from, String to, {bool localRoutes = false}) {
  if (from == to) return null;
  final a = g.node(from);
  final b = g.node(to);
  if (a == null || b == null) return null;
  if (a.here && b.here) {
    // The owner in person is never an end; then the daemon must know local connections at all; then each end must be
    // one the daemon lets write where the owner says (not a wake agent, a worker or a local-model agent).
    if (a.kind == MapNodeKind.you) return DropNote(DropProblem.notConnectable, a);
    if (b.kind == MapNodeKind.you) return DropNote(DropProblem.notConnectable, b);
    if (!localRoutes) return const DropNote(DropProblem.localUnsupported);
    if (!a.connectable) return DropNote(DropProblem.notConnectable, a);
    if (!b.connectable) return DropNote(DropProblem.notConnectable, b);
    return DropConnectLocal(a, b);
  }
  if (!a.here && !b.here) return const DropNote(DropProblem.noLocal);
  final local = a.here ? a : b;
  final other = a.here ? b : a;
  if (!local.connectable) return DropNote(DropProblem.notConnectable, local);
  if (!other.connectable) return DropNote(DropProblem.notConnectable, other);
  return DropConnect(local, other);
}

/// `agent_connect` for a line from [local] to [other] with the owner's choices. [tasks] is sent only when it changes
/// the agent's task authority ([currentTasks]), so a default list stays the default (D-88). [peerTasks] goes only to
/// an own computer's agent: a contact's side is that contact's decision and never receives a choice from here.
AgentConnectRequest connectRequestFor({
  required MapNode local,
  required MapNode other,
  required bool own,
  required bool tasks,
  required bool currentTasks,
  required bool peerTasks,
  required String password,
}) =>
    AgentConnectRequest(
      name: local.name,
      contact: other.contact!,
      agent: other.agentName,
      tasks: tasks == currentTasks ? null : tasks,
      peerTasks: own && other.agentName != null ? peerTasks : null,
      password: password,
    );

/// `agent_disconnect` of the line between our agent [agent] and [contact]'s [peerAgent] (its person when `null`).
/// Asking the other side, and its tasks, exist only for an own computer's agent.
AgentDisconnectRequest disconnectRequestFor({
  required String agent,
  required String contact,
  required String? peerAgent,
  required bool own,
  bool stopTasks = false,
  bool ask = true,
  bool peerStopTasks = false,
}) {
  final asks = own && peerAgent != null && ask;
  return AgentDisconnectRequest(
    name: agent,
    contact: contact,
    agent: peerAgent,
    tasks: stopTasks ? false : null,
    peerTasks: asks && peerStopTasks ? false : null,
    ask: !own || peerAgent == null || ask,
  );
}

/// What Disconnect on a selected line (its popover, or Delete) sends: the line's defaults, as the disconnect dialog
/// starts (keep the tasks, ask an own computer to clear its side). `null` for a line nothing here can remove: recent
/// messages, a team, or a line another computer drew to the owner in person.
ConnectionRequest? defaultDisconnectFor(AgentMapGraph g, MapEdge e) {
  if (!e.removable) return null;
  final local = g.node(e.local);
  final other = g.node(e.other);
  if (local == null || other == null || local.kind != MapNodeKind.local) return null;
  if (e.inside) return LocalDisconnectRequest(name: local.name, local: other.name);
  final contact = other.contact;
  if (contact == null) return null;
  return disconnectRequestFor(agent: local.name, contact: contact, peerAgent: other.agentName, own: g.own(other));
}

/// The reply of a connect or disconnect, or the refusal.
final class ConnectOutcome {
  const ConnectOutcome({this.reply, this.error});
  final AgentConnectedReply? reply;
  final Object? error;
}

/// A daemon built before connections: its strict parser refuses the command.
bool connectionsUnknown(XControlException e) =>
    e.code == XErrorCode.unknownCommand || (e.code == XErrorCode.badRequest && e.message.contains('unknown variant'));

/// A daemon built before local connections: its strict parser refuses the `local` field (connections themselves it
/// knows, so nothing else is marked absent).
bool localConnectionsUnknown(XControlException e) =>
    e.code == XErrorCode.badRequest && e.message.contains('unknown field');

mixin AgentMapMixin on ChangeNotifier {
  XDaemon get daemon;

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);
  HelloOk? get hello;
  List<AgentInfo> get agents;
  bool get live;
  void safeNotify();
  void daemonFailed(Object e);
  Future<void> refreshAgents();
  Future<void> refreshContacts();
  Future<void> refreshDevices();
  Future<void> refreshTeams();
  bool get devicesSupported;
  bool get teamsSupported;

  /// List or Map on the Agents page.
  AgentsView agentsView = AgentsView.list;

  /// The last `agent_traffic`; `null` until it answered (or with an older daemon).
  AgentTrafficReply? agentTraffic;

  /// The daemon refused `agent_traffic`, `agent_connect` or `agent_disconnect` as unknown: one built before
  /// connections.
  bool connectionsAbsent = false;

  /// Requests this window's own commands made on own computers (see the file's header).
  final List<PendingConnect> pendingConnects = [];

  Timer? _mapPoll;
  Timer? _mapDebounce;
  int _mapWatchers = 0;

  /// The daemon refused a connection between two agents of this computer as an unknown field.
  bool localConnectionsAbsent = false;

  /// The daemon speaks x-control/7 and has not refused connections.
  bool get connectionsSupported => controlVersion(hello?.proto) >= 7 && !connectionsAbsent;

  /// The daemon knows connections between two agents of this computer: it sends `session.local_routes` (empty or not)
  /// for its agents, which one built before them does not.
  bool get localConnectionsSupported =>
      connectionsSupported && !localConnectionsAbsent && agents.any((a) => a.localRoutes != null);

  void setAgentsView(AgentsView v) {
    agentsView = v;
    safeNotify();
  }

  Future<void> refreshTraffic() async {
    if (!connectionsSupported) return;
    try {
      agentTraffic = expectReply<AgentTrafficReply>(await daemon.call(const AgentTrafficRequest()));
    } on XControlException catch (e) {
      if (connectionsUnknown(e)) {
        connectionsAbsent = true;
        agentTraffic = null;
      }
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) daemonFailed(e);
    }
    safeNotify();
  }

  /// Everything the map draws.
  Future<void> refreshAgentMap() async {
    await Future.wait([
      refreshAgents(),
      refreshContacts(),
      if (devicesSupported) refreshDevices(),
      if (teamsSupported) refreshTeams(),
      refreshTraffic(),
    ]);
  }

  /// The map is on screen: read everything now and every 15 s while it stays (a live window only; tests read by hand).
  void watchAgentMap() {
    _mapWatchers++;
    if (live) _mapPoll ??= Timer.periodic(const Duration(seconds: 15), (_) => unawaited(refreshAgentMap()));
  }

  void unwatchAgentMap() {
    if (--_mapWatchers > 0) return;
    _mapWatchers = 0;
    _mapPoll?.cancel();
    _mapPoll = null;
  }

  /// An owner `agent` or `device` event (a line set here or there): the agents and devices are read by their own
  /// handlers; the traffic too while the map is on screen.
  void onAgentMapEvent() {
    if (_mapWatchers == 0) return;
    _mapDebounce?.cancel();
    _mapDebounce = Timer(const Duration(milliseconds: 300), () => unawaited(refreshTraffic()));
  }

  Future<ConnectOutcome> _connection(ConnectionRequest r, {OwnerAuth? auth}) async {
    try {
      final reply = switch ((auth, r)) {
        (final OwnerAuth a, final AgentConnectRequest c) =>
          await ownerOp(a, (d, pw) async => expectReply<AgentConnectedReply>(await d.call(c.withPassword(pw)))),
        (final OwnerAuth a, final LocalConnectRequest c) =>
          await ownerOp(a, (d, pw) async => expectReply<AgentConnectedReply>(await d.call(c.withPassword(pw)))),
        _ => expectReply<AgentConnectedReply>(await daemon.call(r)),
      };
      final side = reply.otherSide;
      if (side.state == OtherSideState.requested && side.id != null) {
        final (contact, agent, peer, off) = switch (r) {
          AgentConnectRequest() => (r.contact, r.name, r.agent, false),
          AgentDisconnectRequest() => (r.contact ?? reply.agent.counterpart?.contact ?? '', r.name, r.agent, true),
          // Both sides of a local connection are set here: nothing waits on another computer.
          LocalConnectRequest() || LocalDisconnectRequest() || AgentTrafficRequest() => ('', '', null, false),
        };
        if (contact.isNotEmpty) {
          pendingConnects
            ..removeWhere((p) => p.contact == contact && p.agent == agent)
            ..add(PendingConnect(id: side.id!, contact: contact, agent: agent, peerAgent: peer, disconnect: off));
        }
      }
      return ConnectOutcome(reply: reply);
    } on XControlException catch (e) {
      final local = r is LocalConnectRequest || r is LocalDisconnectRequest;
      if (local && localConnectionsUnknown(e)) {
        localConnectionsAbsent = true;
      } else if (connectionsUnknown(e)) {
        connectionsAbsent = true;
      }
      return ConnectOutcome(error: e);
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) daemonFailed(e);
      return ConnectOutcome(error: e);
    } finally {
      await Future.wait([refreshAgents(), if (devicesSupported) refreshDevices(), refreshTraffic()]);
    }
  }

  /// `agent_connect`: with [auth] the owner's password or one touch (D-131), otherwise the password in [r].
  Future<ConnectOutcome> connectAgent(AgentConnectRequest r, {OwnerAuth? auth}) => _connection(r, auth: auth);

  /// `agent_disconnect` (no password).
  Future<ConnectOutcome> disconnectAgent(AgentDisconnectRequest r) => _connection(r);

  /// `agent_connect` with `local`: with [auth] the owner's password or one touch (D-131), otherwise the password in
  /// [r].
  Future<ConnectOutcome> connectLocal(LocalConnectRequest r, {OwnerAuth? auth}) => _connection(r, auth: auth);

  /// Any disconnect: of a line to another computer, or between two agents of this computer (no password).
  Future<ConnectOutcome> disconnectLine(ConnectionRequest r) => _connection(r);

  /// The request with [id] waiting on [contact] (an own computer), as its last status lists it.
  (DeviceInfo, DeviceApproval)? waitingRequest(List<DeviceInfo> devices, String contact, String id) {
    final d = devices.where((d) => d.contact == contact).firstOrNull;
    final a = d?.status?.approvals.where((a) => a.id == id).firstOrNull;
    return d == null || a == null ? null : (d, a);
  }

  void clearAgentMap() {
    _mapDebounce?.cancel();
    agentTraffic = null;
    connectionsAbsent = false;
    localConnectionsAbsent = false;
    pendingConnects.clear();
  }

  void disposeAgentMap() {
    _mapPoll?.cancel();
    _mapDebounce?.cancel();
  }
}
