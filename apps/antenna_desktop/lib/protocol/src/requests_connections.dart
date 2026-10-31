// SPDX-License-Identifier: AGPL-3.0-only
// The agent map (x-control/7, CONTROL §30, D-123; experimental): the owner's commands that set or remove an agent's
// default counterpart, a connection between two agents of this computer, and the traffic the map draws. A part of
// requests.dart. None of them exists for an agent. An older v7 daemon refuses them (`bad_request`, "unknown variant");
// the window then draws no connections. One built before local connections refuses `local` (`bad_request`, "unknown
// field").

part of 'requests.dart';

/// Every connection command of the owner (the fake daemon routes them by this type).
sealed class ConnectionRequest extends XRequest {
  const ConnectionRequest();
}

/// Connect our agent [name] to [contact]'s agent [agent] (`null`: the contact's person). [tasks]: our agent takes
/// the contact's messages as tasks (`true`) or as data (`false`); `null` leaves it as it is. [peerTasks] (an own
/// computer only): its agent takes this computer's messages as tasks. [ask] `false` sets only this side; the default
/// (`true`) is left out, as the daemon writes it. The owner password, never printed. Reply: `agent_connected`.
final class AgentConnectRequest extends ConnectionRequest {
  const AgentConnectRequest({
    required this.name,
    required this.contact,
    required this.password,
    this.agent,
    this.tasks,
    this.peerTasks,
    this.ask = true,
  });
  final String name;
  final String contact;
  final String? agent;
  final bool? tasks;
  final bool? peerTasks;
  final bool ask;
  final String password;
  @override
  String get cmd => 'agent_connect';
  @override
  Json get fields => {
        'name': name,
        'contact': contact,
        'agent': ?agent,
        'tasks': ?tasks,
        'peer_tasks': ?peerTasks,
        if (!ask) 'ask': false,
        'password': password,
      };

  /// The same request with another password (Ask again: the window never keeps the one typed before).
  AgentConnectRequest withPassword(String password) => AgentConnectRequest(
        name: name,
        contact: contact,
        agent: agent,
        tasks: tasks,
        peerTasks: peerTasks,
        ask: ask,
        password: password,
      );
}

/// Remove our agent [name]'s connection: without [contact], its default counterpart; with [contact] (and [agent]),
/// that line, also one only the other side drew. [tasks] `false`: also stop taking that contact's messages as tasks;
/// [peerTasks] `false`: ask the other side to do the same; [ask] `false`: do not ask an own computer to clear its side.
/// No password: it only takes away (D-84). Reply: `agent_connected`.
final class AgentDisconnectRequest extends ConnectionRequest {
  const AgentDisconnectRequest({required this.name, this.contact, this.agent, this.tasks, this.peerTasks, this.ask = true});
  final String name;
  final String? contact;
  final String? agent;
  final bool? tasks;
  final bool? peerTasks;
  final bool ask;
  @override
  String get cmd => 'agent_disconnect';
  @override
  Json get fields => {
        'name': name,
        'contact': ?contact,
        'agent': ?agent,
        'tasks': ?tasks,
        'peer_tasks': ?peerTasks,
        if (!ask) 'ask': false,
      };
}

/// Connect our agent [name] with [local], another agent of this computer: [name]'s messages without an address go to
/// [local]; with [ask] (the default, left out) [local]'s go to [name] too. [tasks]: [name] takes [local]'s messages as
/// tasks; [peerTasks]: [local] takes [name]'s. The owner password, never printed. Reply: `agent_connected` with
/// `other_side.state` `local` (`not_asked` without [ask]).
final class LocalConnectRequest extends ConnectionRequest {
  const LocalConnectRequest({
    required this.name,
    required this.local,
    required this.password,
    this.tasks,
    this.peerTasks,
    this.ask = true,
  });
  final String name;
  final String local;
  final bool? tasks;
  final bool? peerTasks;
  final bool ask;
  final String password;
  @override
  String get cmd => 'agent_connect';
  @override
  Json get fields => {
        'name': name,
        'local': local,
        'tasks': ?tasks,
        'peer_tasks': ?peerTasks,
        if (!ask) 'ask': false,
        'password': password,
      };

  /// The same request with another password (one the owner typed, or the one-touch path's, D-131).
  LocalConnectRequest withPassword(String password) => LocalConnectRequest(
        name: name,
        local: local,
        tasks: tasks,
        peerTasks: peerTasks,
        ask: ask,
        password: password,
      );
}

/// Remove the connection between our agents [name] and [local], both ways (either one's default counterpart is cleared
/// when it is the other). [tasks] / [peerTasks] `false`: also stop taking the other's messages as tasks. No password:
/// it only takes away (D-84). Reply: `agent_connected` with `other_side.state` `local`.
final class LocalDisconnectRequest extends ConnectionRequest {
  const LocalDisconnectRequest({required this.name, required this.local, this.tasks, this.peerTasks});
  final String name;
  final String local;
  final bool? tasks;
  final bool? peerTasks;
  @override
  String get cmd => 'agent_disconnect';
  @override
  Json get fields => {'name': name, 'local': local, 'tasks': ?tasks, 'peer_tasks': ?peerTasks};
}

/// Who talked to whom in the last [days] (the daemon's default 30 when `null`). Reply: `agent_traffic`.
final class AgentTrafficRequest extends ConnectionRequest {
  const AgentTrafficRequest({this.days});
  final int? days;
  @override
  String get cmd => 'agent_traffic';
  @override
  Json get fields => {'days': ?days};
}
