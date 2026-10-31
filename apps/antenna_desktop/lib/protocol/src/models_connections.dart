// SPDX-License-Identifier: AGPL-3.0-only
// The agent map (x-control/7, CONTROL §30, D-123; experimental): an agent's default counterpart, its connections to
// other agents of this computer, what became of the other side of a connection, and who talked to whom recently. A
// part of models.dart. The counterpart and the local connections are the owner's settings, read from `agent_list`
// (`session.counterpart`, `session.local_routes`); traffic is derived by the daemon from the stored messages, like
// chats.

part of 'models.dart';

/// An agent's default counterpart: a contact's agent, the contact's person when [agent] is `null`, or another agent of
/// this computer when [local] is set ([contact] is then `""`).
final class Counterpart {
  const Counterpart({required this.contact, this.agent, this.local = false});

  factory Counterpart.fromJson(Json j) =>
      Counterpart(contact: _optStr(j, 'contact') ?? '', agent: _optStr(j, 'agent'), local: j['local'] == true);

  /// The contact's label; `""` for an agent of this computer.
  final String contact;

  /// The contact's agent, by the name it announced (an agent of this computer when [local]); `null`: the contact's
  /// person.
  final String? agent;

  /// An agent of this computer (a local connection; a daemon that sends `local_routes`).
  final bool local;

  bool get person => agent == null && !local;

  @override
  bool operator ==(Object other) =>
      other is Counterpart && other.contact == contact && other.agent == agent && other.local == local;

  @override
  int get hashCode => Object.hash(contact, agent, local);

  @override
  String toString() => 'Counterpart(${local ? 'local:' : ''}$contact${agent == null ? '' : ':$agent'})';
}

/// One connection of an agent to another agent of this computer (`session.local_routes[]`).
final class LocalRoute {
  const LocalRoute({required this.agent, this.tasks = false});

  factory LocalRoute.fromJson(Json j) => LocalRoute(agent: _str(j, 'agent'), tasks: _bool(j, 'tasks'));

  /// The other agent of this computer.
  final String agent;

  /// This agent takes [agent]'s messages as tasks.
  final bool tasks;

  @override
  bool operator ==(Object other) => other is LocalRoute && other.agent == agent && other.tasks == tasks;

  @override
  int get hashCode => Object.hash(agent, tasks);

  @override
  String toString() => 'LocalRoute($agent${tasks ? ', tasks' : ''})';
}

/// The default counterpart in an agent's session (v7, CONTROL §30). Read from the original JSON, so the agent model
/// stays as it is for older daemons, which do not send it.
extension AgentConnection on AgentInfo {
  /// Where this agent's messages without an address go; `null`: nowhere (or an older daemon).
  Counterpart? get counterpart {
    final s = raw['session'];
    final c = s is Map<String, Object?> ? s['counterpart'] : null;
    if (c is! Map<String, Object?>) return null;
    final contact = c['contact'];
    final agent = c['agent'];
    final local = c['local'] == true;
    // A local counterpart is an agent of this computer by name; any other names its contact.
    if (local ? agent is! String : contact is! String) return null;
    return Counterpart(contact: contact is String ? contact : '', agent: agent is String ? agent : null, local: local);
  }

  /// The agents of this computer it is connected to; `null` when the daemon does not send `local_routes` (one built
  /// before local connections: a newer one always sends the key, empty or not).
  List<LocalRoute>? get localRoutes {
    final s = raw['session'];
    final r = s is Map<String, Object?> ? s['local_routes'] : null;
    if (r is! List) return null;
    return [
      for (final x in r)
        if (x is Map<String, Object?> && x['agent'] is String) LocalRoute.fromJson(x),
    ];
  }
}

/// The values of [OtherSide.state].
abstract final class OtherSideState {
  /// An approval request was made on the other own computer ([OtherSide.id] is its ID there).
  static const requested = 'requested';

  /// That computer already has exactly this.
  static const unchanged = 'unchanged';

  /// A contact that is not an own computer: only this side changed.
  static const contactDecides = 'contact_decides';

  /// The counterpart is a person.
  static const person = 'person';

  /// `ask: false`.
  static const notAsked = 'not_asked';

  /// The other own computer's Antenna does not know connections yet.
  static const unsupported = 'unsupported';

  /// It could not be reached now; this side is set.
  static const unreachable = 'unreachable';

  /// It refused ([OtherSide.code], [OtherSide.message]).
  static const refused = 'refused';

  /// A connection between two agents of this computer: both sides are set here.
  static const local = 'local';
}

/// What became of the other side of a connection.
final class OtherSide {
  const OtherSide({required this.state, this.id, this.message, this.code});

  factory OtherSide.fromJson(Json j) => OtherSide(
        state: _str(j, 'state'),
        id: _optStr(j, 'id'),
        message: _optStr(j, 'message'),
        code: _optStr(j, 'code'),
      );

  /// [OtherSideState]; a value this window does not know is shown as the daemon's word.
  final String state;

  /// `requested`: the approval request's ID on that computer.
  final String? id;

  /// `unreachable`, `refused`: why, in the daemon's English words.
  final String? message;

  /// `refused`: the other computer's error code.
  final String? code;
}

/// `agent_connected`: the reply of `agent_connect` and `agent_disconnect`: our agent as it is now, and the other side.
final class AgentConnectedReply extends Reply {
  const AgentConnectedReply({required this.agent, required this.otherSide});

  factory AgentConnectedReply.fromJson(Json j) => AgentConnectedReply(
        agent: AgentInfo.fromJson(_obj(j, 'agent')),
        otherSide: OtherSide.fromJson(_obj(j, 'other_side')),
      );

  final AgentInfo agent;
  final OtherSide otherSide;

  @override
  String toString() => 'AgentConnectedReply(${agent.name}, ${otherSide.state})';
}

/// Messages between one of our agents (or the owner in person) and one counterpart of a contact.
final class TrafficPair {
  const TrafficPair({
    required this.agent,
    required this.contact,
    required this.peerAgent,
    required this.lastMs,
    this.sent = 0,
    this.received = 0,
    this.local = false,
  });

  factory TrafficPair.fromJson(Json j) => TrafficPair(
        agent: _optStr(j, 'agent') ?? '',
        contact: _optStr(j, 'contact') ?? '',
        peerAgent: _optStr(j, 'peer_agent') ?? '',
        lastMs: _optInt(j, 'last_ms') ?? 0,
        sent: _optInt(j, 'sent') ?? 0,
        received: _optInt(j, 'received') ?? 0,
        local: j['local'] == true,
      );

  /// Our agent; `""`: the owner in person.
  final String agent;

  /// The contact's label; `""` for two agents of this computer ([local]).
  final String contact;

  /// The contact's agent (another agent of this computer when [local]); `""`: the contact's person.
  final String peerAgent;

  /// Two agents of this computer: [sent] went from [agent] to [peerAgent], [received] the other way.
  final bool local;

  /// The latest message either way (this computer's clock).
  final int lastMs;
  final int sent;
  final int received;
}

/// `agent_traffic`: who talked to whom recently, newest first.
final class AgentTrafficReply extends Reply {
  const AgentTrafficReply({required this.sinceMs, required this.pairs});

  factory AgentTrafficReply.fromJson(Json j) => AgentTrafficReply(
        sinceMs: _optInt(j, 'since_ms') ?? 0,
        pairs: [for (final p in _list(j, 'pairs')) TrafficPair.fromJson(p)],
      );

  final int sinceMs;
  final List<TrafficPair> pairs;
}
