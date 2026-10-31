// SPDX-License-Identifier: AGPL-3.0-only
// The owner's stop switch (x-control/7, CONTROL §33; experimental) on any [XDaemon]: typed calls over `call`, so the
// socket client and the test daemons share one implementation.

import 'daemon.dart';
import 'errors.dart';
import 'models.dart';
import 'requests.dart';

T _as<T extends Reply>(Reply r) {
  if (r is T) return r;
  throw XProtocolException('expected ${T.toString()}, got ${r.runtimeType}');
}

extension AgentStopCommands on XDaemon {
  /// [agent] runs in the terminal session led by [pid], a process this client started (`done`, `noted`).
  Future<void> agentTerminal(String agent, int pid) async =>
      _as<DoneReply>(await call(AgentTerminalRequest(agent: agent, pid: pid)));

  /// Stop [agent] and the processes it started.
  Future<AgentStoppedReply> agentStop(String agent) async =>
      _as<AgentStoppedReply>(await call(AgentStopRequest(agent)));

  /// Ask the own computer [contact] to stop its [agent] and the processes it started.
  Future<AgentStoppedReply> deviceAgentStop(String contact, String agent) async =>
      _as<AgentStoppedReply>(await call(DeviceAgentStopRequest(contact: contact, agent: agent)));
}
