// SPDX-License-Identifier: AGPL-3.0-only
// The owner's stop switch (x-control/7, CONTROL §33; experimental): the requests. A part of requests.dart. A daemon
// older than these commands answers `unknown_command` (or `bad_request` from its strict parser): the window then stops
// only what it started itself (its own terminal).

part of 'requests.dart';

/// The agent runs in the terminal session led by [pid], a process this client started (Code mode's wrapper, the
/// pseudo-terminal's session leader): a later `agent_stop` sweeps that session whole. The daemon checks that [pid] is
/// this client's own child and a session leader; no owner session is needed (after an update restore the window has
/// none). Reply: `done` with `state: "noted"`.
final class AgentTerminalRequest extends XRequest {
  const AgentTerminalRequest({required this.agent, required this.pid});
  final String agent;
  final int pid;
  @override
  String get cmd => 'agent_terminal';
  @override
  Json get fields => {'agent': agent, 'pid': pid};
}

/// Stop [agent] and the processes it started. An owner session, no password: stopping only makes things safer.
/// Reply: `agent_stopped`.
final class AgentStopRequest extends XRequest {
  const AgentStopRequest(this.agent);
  final String agent;
  @override
  String get cmd => 'agent_stop';
  @override
  Json get fields => {'agent': agent};
}

/// Ask the own computer [contact] to stop its agent [agent] and the processes it started (that computer decides and
/// does it; both sides at ∞). An owner session, no password. Reply: `agent_stopped` with `contact`.
final class DeviceAgentStopRequest extends XRequest {
  const DeviceAgentStopRequest({required this.contact, required this.agent});
  final String contact;
  final String agent;
  @override
  String get cmd => 'device_agent_stop';
  @override
  Json get fields => {'contact': contact, 'agent': agent};
}
