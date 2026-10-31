// SPDX-License-Identifier: AGPL-3.0-only
// The fake daemon's stop switch (x-control/7, CONTROL §33): what the window registered with `agent_terminal`, what it
// asked to stop here and on another own computer, and the replies the test chooses. With [agentStopEnabled] off the
// fake answers like a daemon from before the switch (`unknown_command`); the real sweep of a terminal session is in
// the daemon's own tests and the live test.

import 'package:antenna_desktop/protocol/x_control.dart';

mixin FakeAgentStop {
  int get protoVersion;

  /// `false`: a daemon built before the stop switch.
  bool agentStopEnabled = true;

  /// `agent_terminal` calls: (agent, pid), in order.
  final agentTerminals = <(String, int)>[];

  /// `agent_stop` calls, in order.
  final agentStops = <String>[];

  /// `device_agent_stop` calls: (contact, agent), in order.
  final deviceAgentStops = <(String, String)>[];

  /// The next `agent_stop` reply's `how`, counts and names (the agent's name is the one asked).
  String stopHow = StopHow.terminal;
  int stopProcesses = 4;
  int stopLeft = 0;
  List<String> stopNames = const ['claude', 'node', 'sleep'];

  /// Raised by the next stop instead of a reply.
  XControlException? stopRefusal;

  /// Called on `agent_stop` before the reply (a test ends the agent's terminal here, as the daemon's sweep would).
  void Function(String agent)? onAgentStop;

  Reply agentStopCall(XRequest r) {
    if (protoVersion < 7 || !agentStopEnabled) {
      throw XControlException(XErrorCode.unknownCommand, 'unknown command `${r.cmd}`');
    }
    switch (r) {
      case AgentTerminalRequest(:final agent, :final pid):
        agentTerminals.add((agent, pid));
        return const DoneReply(DaemonState.unknown);
      case AgentStopRequest(:final agent):
        agentStops.add(agent);
        if (stopRefusal case final e?) {
          stopRefusal = null;
          throw e;
        }
        onAgentStop?.call(agent);
        return AgentStoppedReply(
            agent: agent, how: stopHow, processes: stopProcesses, left: stopLeft, names: stopNames);
      case DeviceAgentStopRequest(:final contact, :final agent):
        deviceAgentStops.add((contact, agent));
        if (stopRefusal case final e?) {
          stopRefusal = null;
          throw e;
        }
        return AgentStoppedReply(
            agent: agent, contact: contact, how: stopHow, processes: stopProcesses, left: stopLeft, names: stopNames);
      default:
        throw XControlException(XErrorCode.notImplemented, 'fake: ${r.cmd}');
    }
  }
}
