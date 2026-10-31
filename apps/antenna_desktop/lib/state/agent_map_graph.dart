// SPDX-License-Identifier: AGPL-3.0-only
// The agent map's graph (x-control/7, CONTROL §30, D-123; experimental): clusters (this computer, the owner's other
// computers, the contacts), their nodes, and the lines between them, built from what the daemon said every time the map
// is drawn. Derived state (principle 4): nothing here is kept or sent; the daemon's records are the truth.
//
// Own computer or contact: every entry of `devices` (the daemon lists every contact at level 5 there, CONTROL §27) and
// every contact at level 5 (∞) is an own computer, also when `devices` is missing, refused or not read yet, or when
// that computer has not reported itself (`status` absent): such a cluster says it waits for its report. Everything
// else is a contact. The level is this computer's own setting (`trust`), never what the other side says.

import '../protocol/x_control.dart';

enum MapClusterKind {
  /// This computer: its agents.
  here,

  /// One of the owner's other computers (a contact at ∞).
  ownComputer,

  /// A contact (levels 1–4): its person and its agents.
  contact,
}

enum MapNodeKind {
  /// One of this computer's agents.
  local,

  /// The owner in person on this computer: shown only when another computer's agent points at them.
  you,

  /// An agent of one of the owner's other computers.
  device,

  /// A contact's agent.
  contactAgent,

  /// A contact's person.
  person,
}

/// Why a node cannot be an end of a line (the daemon refuses these: it decides where they write, CONTROL §30).
enum MapNotConnectable {
  /// A link's wake agent.
  wake,

  /// A team's worker.
  worker,

  /// An agent on a local model of this computer.
  localModel,

  /// An agent on a local model of another own computer.
  remoteLocalModel,

  /// The owner in person: one end must be an agent.
  you,
}

final class MapNode {
  const MapNode({
    required this.id,
    required this.cluster,
    required this.name,
    required this.kind,
    this.contact,
    this.notConnectable,
    this.live,
    this.app,
    this.team,
  });

  final String id;
  final String cluster;

  /// The agent's name, or the contact's label for a person.
  final String name;
  final MapNodeKind kind;

  /// A node of another computer: the contact's label (the link the line goes over).
  final String? contact;
  final MapNotConnectable? notConnectable;

  /// The status dot: `true` connected or online, `false` idle or offline, `null` not known.
  final bool? live;

  /// An agent of another own computer: the program it runs as, as that computer said (`claude`, `codex`, `local`).
  final String? app;

  /// A worker: its team.
  final String? team;

  /// On this computer.
  bool get here => kind == MapNodeKind.local || kind == MapNodeKind.you;
  bool get connectable => notConnectable == null;
  bool get person => kind == MapNodeKind.person || kind == MapNodeKind.you;

  /// The name an agent end has on its link (`agent` of the commands); `null` for a person.
  String? get agentName => person ? null : name;
}

final class MapCluster {
  const MapCluster({
    required this.id,
    required this.kind,
    required this.title,
    required this.nodes,
    this.trust = 5,
    this.online,
    this.supported = true,
    this.reportMissing = false,
  });

  final String id;
  final MapClusterKind kind;

  /// The contact's label; this computer's own name for [MapClusterKind.here] (empty when not known).
  final String title;
  final List<MapNode> nodes;
  final int trust;

  /// `true` online, `false` offline, `null` not tracked.
  final bool? online;

  /// An own computer whose Antenna tells this one about itself (`devices[].supported`).
  final bool supported;

  /// An own computer whose report (`devices[].status`) this computer does not have: its agents show once it arrives.
  final bool reportMissing;
}

enum MapEdgeKind {
  /// A default counterpart, set on one side or both.
  configured,

  /// Our side is set; the other own computer has the request waiting for the owner's approval.
  waiting,

  /// Messages went between the two recently, with no line set between them.
  traffic,

  /// A team: its lead and a worker.
  team,
}

final class MapEdge {
  const MapEdge({
    required this.kind,
    required this.local,
    required this.other,
    this.toOther = false,
    this.toLocal = false,
    this.tasksLocal = false,
    this.tasksOther = false,
    this.lastMs,
    this.sent = 0,
    this.received = 0,
    this.team,
    this.waitingOn,
    this.requestId,
    this.inside = false,
  });

  final MapEdgeKind kind;

  /// The end on this computer (one of its agents, or the owner in person).
  final String local;

  /// The other end (for a team line, the worker; for a line [inside] this computer, its other agent).
  final String other;

  /// Both ends are agents of this computer: a team, a local connection, or their recent messages.
  final bool inside;

  /// [local]'s counterpart is [other] (its messages without an address go there), and the other way round.
  final bool toOther;
  final bool toLocal;

  /// That end takes the other end's messages as tasks.
  final bool tasksLocal;
  final bool tasksOther;

  /// Traffic: the latest message either way, and how many went each way.
  final int? lastMs;
  final int sent;
  final int received;

  /// A team line: the team's name.
  final String? team;

  /// Waiting: the own computer where the request waits, and its ID there.
  final String? waitingOn;
  final String? requestId;

  bool get mutual => toOther && toLocal;

  /// A line the owner can disconnect from here (it has a counterpart on one side at least). Recent messages and a
  /// team are never removable: they are history and a team's own structure.
  bool get removable => kind == MapEdgeKind.configured || kind == MapEdgeKind.waiting;

  /// A connection between two agents of this computer.
  bool get localConnection => inside && kind == MapEdgeKind.configured;

  String get key => '${kind.name}:$local>$other';
}

final class AgentMapGraph {
  AgentMapGraph(this.clusters, this.edges) : _nodes = {for (final c in clusters) for (final n in c.nodes) n.id: n};

  final List<MapCluster> clusters;

  /// In painting order: traffic and team lines first, the lines that are set on top.
  final List<MapEdge> edges;
  final Map<String, MapNode> _nodes;

  MapNode? node(String id) => _nodes[id];
  Iterable<MapNode> get nodes => _nodes.values;
  MapCluster? cluster(String id) => clusters.where((c) => c.id == id).firstOrNull;
  MapCluster? clusterOf(MapNode n) => cluster(n.cluster);

  /// [n]'s side ends on another own computer.
  bool own(MapNode n) => clusterOf(n)?.kind == MapClusterKind.ownComputer;

  /// The line set between [a] and [b], if any.
  MapEdge? lineBetween(String a, String b) => edges
      .where((e) => e.removable && ((e.local == a && e.other == b) || (e.local == b && e.other == a)))
      .firstOrNull;
}

/// A request this window's `agent_connect` (or `agent_disconnect`) made on an own computer: its ID there.
final class PendingConnect {
  const PendingConnect({required this.id, required this.contact, required this.agent, this.peerAgent, this.disconnect = false});
  final String id;

  /// The own computer (the contact's label).
  final String contact;

  /// Our agent and the agent there (`null`: its person).
  final String agent;
  final String? peerAgent;
  final bool disconnect;
}

String hereNodeId(String agent) => 'here/$agent';
const youNodeId = 'here:you';
String clusterIdOf(String contact) => 'c/$contact';
String remoteNodeId(String contact, String? agent) => agent == null ? 'c/$contact/p' : 'c/$contact/a/$agent';

class _ClusterDraft {
  _ClusterDraft(this.id, this.kind, this.title,
      {this.trust = 5, this.online, this.supported = true, this.reportMissing = false});
  final String id;
  final MapClusterKind kind;
  final String title;
  final int trust;
  final bool? online;
  final bool supported;
  final bool reportMissing;
  final nodes = <MapNode>[];
  bool has(String id) => nodes.any((n) => n.id == id);

  MapCluster freeze() => MapCluster(
      id: id,
      kind: kind,
      title: title,
      nodes: List.unmodifiable(nodes),
      trust: trust,
      online: online,
      supported: supported,
      reportMissing: reportMissing);
}

class _LineDraft {
  _LineDraft(this.local, this.other);
  final String local;
  final String other;
  bool toOther = false;
  bool toLocal = false;
  String? waitingOn;
  String? requestId;

  /// A local connection: whether each end takes the other's messages as tasks (from `local_routes`).
  bool? tasksLocal;
  bool? tasksOther;
}

/// The map from what the daemon said. [wakeAgents]: the agents of the link wake rules; [localAgents]: the local-model
/// agents (they are in [agents] too, with `local_model`, on daemons that list them); [pending]: requests this window's
/// own commands made on an own computer. Deterministic: the same facts give the same clusters, nodes and lines.
AgentMapGraph buildAgentMap({
  required List<AgentInfo> agents,
  List<String> localAgents = const [],
  Set<String> wakeAgents = const {},
  List<TeamInfo> teams = const [],
  String thisName = '',
  List<DeviceInfo> devices = const [],
  List<ContactInfo> contacts = const [],
  List<TrafficPair> traffic = const [],
  List<PendingConnect> pending = const [],
}) {
  final b = _MapBuilder(agents, localAgents, wakeAgents, teams, thisName)
    ..addHere()
    ..addRemote(devices, contacts)
    ..addSet(devices)
    ..addLocal()
    ..addWaiting(devices, pending);
  return b.build(traffic);
}

class _MapBuilder {
  _MapBuilder(this.agents, List<String> localAgents, this.wake, this.teams, String thisName)
      : here = _ClusterDraft('here', MapClusterKind.here, thisName),
        byName = {for (final a in agents) a.name: a},
        localModel = {...localAgents, for (final a in agents) if (a.localModel != null) a.name},
        localAgents = localAgents,
        workerTeam = {
          for (final t in teams)
            for (final w in t.workers) w.name: t.name,
        };

  final List<AgentInfo> agents;
  final List<String> localAgents;
  final Set<String> wake;
  final List<TeamInfo> teams;
  final _ClusterDraft here;
  final Map<String, AgentInfo> byName;
  final Set<String> localModel;
  final Map<String, String> workerTeam;

  /// The other computers and contacts, by the contact's label, in drawing order.
  final remote = <String, _ClusterDraft>{};
  final order = <_ClusterDraft>[];

  /// What each own computer said about its agents.
  final statusAgents = <String, Map<String, DeviceAgent>>{};
  final lines = <String, _LineDraft>{};

  void _local(String name, {bool? live}) {
    if (here.has(hereNodeId(name))) return;
    final team = workerTeam[name];
    here.nodes.add(MapNode(
      id: hereNodeId(name),
      cluster: here.id,
      name: name,
      kind: MapNodeKind.local,
      live: live,
      team: team,
      notConnectable: team != null
          ? MapNotConnectable.worker
          : localModel.contains(name)
              ? MapNotConnectable.localModel
              : wake.contains(name)
                  ? MapNotConnectable.wake
                  : null,
    ));
  }

  bool _live(String name) => byName[name]?.binding?.alive ?? false;

  void _workersOf(TeamInfo t) {
    for (final w in t.workers) {
      if (w.state != WorkerState.stopped) _local(w.name, live: w.state == WorkerState.busy);
    }
  }

  /// This computer: its agents, each lead followed by its team's workers, then the wake agents, the local-model agents
  /// and the workers of the teams the owner leads.
  void addHere() {
    bool plain(String n) => !workerTeam.containsKey(n) && !localModel.contains(n) && !wake.contains(n);
    for (final a in agents) {
      if (!plain(a.name)) continue;
      _local(a.name, live: _live(a.name));
      for (final t in teams) {
        if (t.lead == a.name) _workersOf(t);
      }
    }
    for (final a in agents) {
      if (wake.contains(a.name) && !workerTeam.containsKey(a.name)) _local(a.name, live: _live(a.name));
    }
    for (final name in [for (final a in agents) a.name, ...localAgents]) {
      if (localModel.contains(name) && !workerTeam.containsKey(name)) _local(name);
    }
    teams.forEach(_workersOf);
  }

  /// The owner's other computers (what each said about its agents, and the agents it announced on the link), then
  /// the contacts with their person and agents; a contact at ∞ that does not report itself is an own computer too
  /// (see the file's header).
  void addRemote(List<DeviceInfo> devices, List<ContactInfo> contacts) {
    final byLabel = {for (final c in contacts) c.label: c};
    for (final d in devices) {
      final c = _ClusterDraft(clusterIdOf(d.contact), MapClusterKind.ownComputer, d.contact,
          online: d.online, supported: d.supported, reportMissing: d.status == null);
      final said = {for (final a in d.status?.agents ?? const <DeviceAgent>[]) a.name: a};
      statusAgents[d.contact] = said;
      for (final a in said.values) {
        c.nodes.add(MapNode(
          id: remoteNodeId(d.contact, a.name),
          cluster: c.id,
          name: a.name,
          kind: MapNodeKind.device,
          contact: d.contact,
          app: a.app,
          live: a.state == 'connected',
          notConnectable: a.app == 'local' || a.state == 'local' ? MapNotConnectable.remoteLocalModel : null,
        ));
      }
      for (final a in byLabel[d.contact]?.activeAgents ?? const <PeerAgent>[]) {
        if (!c.has(remoteNodeId(d.contact, a.name))) {
          c.nodes.add(MapNode(
              id: remoteNodeId(d.contact, a.name), cluster: c.id, name: a.name, kind: MapNodeKind.device, contact: d.contact));
        }
      }
      remote[d.contact] = c;
      order.add(c);
    }
    final people = <_ClusterDraft>[];
    for (final ct in contacts) {
      if (remote.containsKey(ct.label)) continue;
      final own = ct.trust >= 5;
      final online = ct.presence == 'online' ? true : (ct.presence == 'offline' ? false : null);
      final c = _ClusterDraft(clusterIdOf(ct.label), own ? MapClusterKind.ownComputer : MapClusterKind.contact, ct.label,
          trust: ct.trust, online: online, supported: !own, reportMissing: own);
      if (!own) {
        c.nodes.add(MapNode(
            id: remoteNodeId(ct.label, null), cluster: c.id, name: ct.label, kind: MapNodeKind.person, contact: ct.label,
            live: online));
      }
      for (final a in ct.activeAgents) {
        c.nodes.add(MapNode(
            id: remoteNodeId(ct.label, a.name),
            cluster: c.id,
            name: a.name,
            kind: own ? MapNodeKind.device : MapNodeKind.contactAgent,
            contact: ct.label));
      }
      remote[ct.label] = c;
      (own ? order : people).add(c);
    }
    order.addAll(people);
  }

  /// The node of [contact]'s [agent] (its person when `null`), added when the daemon names one the cluster does not
  /// list yet (an agent that wrote, or one a line points at); `null` when there is no such contact.
  String? _remoteNode(String contact, String? agent) {
    final c = remote[contact];
    if (c == null) return null;
    final id = remoteNodeId(contact, agent);
    if (c.has(id)) return id;
    if (agent == null && c.kind == MapClusterKind.ownComputer) return null;
    c.nodes.add(MapNode(
      id: id,
      cluster: c.id,
      name: agent ?? contact,
      kind: agent == null
          ? MapNodeKind.person
          : (c.kind == MapClusterKind.ownComputer ? MapNodeKind.device : MapNodeKind.contactAgent),
      contact: contact,
    ));
    return id;
  }

  _LineDraft _line(String local, String other) => lines.putIfAbsent('$local>$other', () => _LineDraft(local, other));

  /// The line between two agents of this computer, whichever of them it was started from; `true` when [a] is its
  /// other end.
  (_LineDraft, bool) _localLine(String a, String b) {
    if (lines['$b>$a'] case final l?) return (l, true);
    return (_line(a, b), false);
  }

  /// Local connections (a daemon that sends `local_routes`): each agent's routes to the agents of this computer, and a
  /// counterpart that is one of them. One line per pair, started from the first of the two in the daemon's order.
  void addLocal() {
    for (final a in agents) {
      final from = hereNodeId(a.name);
      if (!here.has(from)) continue;
      for (final r in a.localRoutes ?? const <LocalRoute>[]) {
        final to = hereNodeId(r.agent);
        if (to == from || !here.has(to)) continue;
        final (l, swapped) = _localLine(from, to);
        if (swapped) {
          l.tasksOther = r.tasks;
        } else {
          l.tasksLocal = r.tasks;
        }
      }
      final cp = a.counterpart;
      if (cp == null || !cp.local || cp.agent == null) continue;
      final to = hereNodeId(cp.agent!);
      if (to == from || !here.has(to)) continue;
      final (l, swapped) = _localLine(from, to);
      if (swapped) {
        l.toLocal = true;
      } else {
        l.toOther = true;
      }
    }
  }

  /// The lines that are set: our agents' counterparts, and the own computers' agents whose counterpart is one of ours
  /// (or the owner in person, who then gets a node of their own).
  void addSet(List<DeviceInfo> devices) {
    for (final a in agents) {
      final cp = a.counterpart;
      if (cp == null || cp.local || !here.has(hereNodeId(a.name))) continue;
      final other = _remoteNode(cp.contact, cp.agent);
      if (other != null) _line(hereNodeId(a.name), other).toOther = true;
    }
    for (final d in devices) {
      for (final x in statusAgents[d.contact]!.values) {
        final cp = x.counterpart;
        if (cp == null) continue;
        final String local;
        if (cp.isEmpty) {
          if (!here.has(youNodeId)) {
            here.nodes.insert(0, const MapNode(
                id: youNodeId, cluster: 'here', name: '', kind: MapNodeKind.you, notConnectable: MapNotConnectable.you));
          }
          local = youNodeId;
        } else if (here.has(hereNodeId(cp))) {
          local = hereNodeId(cp);
        } else {
          continue;
        }
        _line(local, _remoteNode(d.contact, x.name)!).toLocal = true;
      }
    }
  }

  /// A line waits while the request this window made for it is still pending on that computer.
  void addWaiting(List<DeviceInfo> devices, List<PendingConnect> pending) {
    for (final p in pending) {
      final waits = devices.where((d) => d.contact == p.contact).firstOrNull?.status?.approvals.any((a) => a.id == p.id);
      if (waits != true || !here.has(hereNodeId(p.agent))) continue;
      final other = _remoteNode(p.contact, p.peerAgent);
      if (other == null) continue;
      if (p.disconnect && !lines.containsKey('${hereNodeId(p.agent)}>$other')) continue;
      final l = _line(hereNodeId(p.agent), other);
      if (!p.disconnect) l.toOther = true;
      l
        ..waitingOn = p.contact
        ..requestId = p.id;
    }
  }

  MapNode? _node(String id) {
    for (final c in [here, ...order]) {
      for (final n in c.nodes) {
        if (n.id == id) return n;
      }
    }
    return null;
  }

  bool _takesTasks(String localId, String contact) {
    final n = _node(localId);
    if (n == null || n.kind != MapNodeKind.local) return false;
    return byName[n.name]?.tasksFrom?.contains(contact) ?? false;
  }

  /// Recent traffic where no line is set: newest first, one line per pair; the owner's own messages are not a line.
  List<MapEdge> _traffic(List<TrafficPair> traffic) {
    final talked = <MapEdge>[];
    for (final p in traffic) {
      if (p.agent.isEmpty || !here.has(hereNodeId(p.agent))) continue;
      final local = hereNodeId(p.agent);
      if (p.local) {
        // Two agents of this computer: one line per pair, whichever way the pair is listed.
        final other = hereNodeId(p.peerAgent);
        if (p.peerAgent.isEmpty || other == local || !here.has(other)) continue;
        if (lines.containsKey('$local>$other') || lines.containsKey('$other>$local')) continue;
        bool pair(MapEdge e) => (e.local == local && e.other == other) || (e.local == other && e.other == local);
        if (talked.any(pair)) continue;
        talked.add(MapEdge(
            kind: MapEdgeKind.traffic,
            local: local,
            other: other,
            lastMs: p.lastMs,
            sent: p.sent,
            received: p.received,
            inside: true));
        continue;
      }
      final other = _remoteNode(p.contact, p.peerAgent.isEmpty ? null : p.peerAgent);
      if (other == null) continue;
      if (lines.containsKey('$local>$other') || talked.any((e) => e.local == local && e.other == other)) continue;
      talked.add(MapEdge(
          kind: MapEdgeKind.traffic, local: local, other: other, lastMs: p.lastMs, sent: p.sent, received: p.received));
    }
    return talked;
  }

  /// A team: its lead to each worker drawn.
  List<MapEdge> _teams() => [
        for (final t in teams)
          if (t.lead case final lead? when here.has(hereNodeId(lead)))
            for (final w in t.workers)
              if (here.has(hereNodeId(w.name)) && w.name != lead)
                MapEdge(
                    kind: MapEdgeKind.team,
                    local: hereNodeId(lead),
                    other: hereNodeId(w.name),
                    team: t.name,
                    inside: true),
      ];

  /// The graph; the lines in painting order: traffic and teams first, the lines that wait, then those that are set.
  AgentMapGraph build(List<TrafficPair> traffic) {
    final talked = _traffic(traffic);
    final set = [
      for (final l in lines.values)
        if (_node(l.other) case final other?)
          MapEdge(
            kind: l.waitingOn != null ? MapEdgeKind.waiting : MapEdgeKind.configured,
            local: l.local,
            other: l.other,
            toOther: l.toOther,
            toLocal: l.toLocal,
            tasksLocal:
                other.kind == MapNodeKind.local ? (l.tasksLocal ?? false) : _takesTasks(l.local, other.contact ?? ''),
            tasksOther: other.kind == MapNodeKind.local
                ? (l.tasksOther ?? false)
                : other.kind == MapNodeKind.device && (statusAgents[other.contact]?[other.name]?.takesTasks ?? false),
            waitingOn: l.waitingOn,
            requestId: l.requestId,
            inside: other.kind == MapNodeKind.local,
          ),
    ];
    return AgentMapGraph(
      [here.freeze(), for (final c in order) c.freeze()],
      [
        ...talked,
        ..._teams(),
        ...set.where((e) => e.kind == MapEdgeKind.waiting),
        ...set.where((e) => e.kind == MapEdgeKind.configured),
      ],
    );
  }
}
