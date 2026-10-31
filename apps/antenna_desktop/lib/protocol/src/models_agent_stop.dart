// SPDX-License-Identifier: AGPL-3.0-only
// The owner's stop switch (x-control/7, CONTROL §33; experimental): what a stop took. A part of models.dart. The
// process names come from the system (another computer's, for `device_agent_stop`): plain text for the window.

part of 'models.dart';

/// How an agent was stopped (`agent_stopped.how`).
abstract final class StopHow {
  /// Its own terminal session that Antenna started (the window's tab, `antenna session`), swept whole.
  static const terminal = 'terminal';

  /// An agent CLI the owner started in a terminal of their own: that process and everything under it.
  static const process = 'process';

  /// An AI app the owner runs (Claude Desktop, Cursor…): not quit; the agent is disconnected, its token replaced.
  static const app = 'app';

  /// The link's wake agent: its sandbox.
  static const resident = 'resident';
  static const wake = 'wake';

  /// A team worker: its sandbox.
  static const worker = 'worker';

  /// A local model's agent: its turn ended.
  static const local = 'local';

  /// Nothing ran.
  static const none = 'none';
}

/// `agent_stopped` (`agent_stop`, `device_agent_stop`).
final class AgentStoppedReply extends Reply {
  const AgentStoppedReply({
    required this.agent,
    required this.how,
    required this.processes,
    required this.left,
    this.contact,
    this.names = const [],
  });

  factory AgentStoppedReply.fromJson(Json j) => AgentStoppedReply(
        agent: _str(j, 'agent'),
        contact: _optStr(j, 'contact'),
        how: _optStr(j, 'how') ?? StopHow.none,
        processes: _optInt(j, 'processes') ?? 0,
        left: _optInt(j, 'left') ?? 0,
        names: _strList(j, 'names'),
      );

  final String agent;

  /// The own computer that stopped it (`device_agent_stop`); `null`: this one.
  final String? contact;

  /// [StopHow].
  final String how;

  /// How many processes got a signal.
  final int processes;

  /// How many were still alive afterwards (normally 0).
  final int left;

  /// Their distinct names, at most 16.
  final List<String> names;
}
