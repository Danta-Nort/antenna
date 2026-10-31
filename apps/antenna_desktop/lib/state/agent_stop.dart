// SPDX-License-Identifier: AGPL-3.0-only
// "Stop agent and its processes" (CONTROL §33, experimental): the owner's stop switch for an agent that hung or runs
// away, here or on an own computer. The daemon does the stopping (`agent_stop`, `device_agent_stop`): an agent in a
// terminal session Antenna started is swept with its whole session, an agent CLI in the owner's own terminal with
// everything under it, an AI app's agent is disconnected (the app is not quit), a wake agent or a worker loses its
// sandbox. No password: stopping only makes things safer.
//
// For a Code mode tab the window tells the daemon which terminal session the agent runs in (`agent_terminal`, the
// wrapper's PID, which leads the pseudo-terminal's session), right after the start and after every reconnect, so a
// stop from here or from another own computer sweeps that session whole. The tab is marked stopped by the owner before
// the call, so it says "Stopped" when the sweep ends the process; whatever is still alive afterwards the window stops
// itself as before (SIGHUP to the group, then SIGKILL). With a daemon older than these commands, or when the daemon
// cannot do it, the window stops only its own terminal and says so.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'agent_status.dart';
import 'code_mode.dart';

/// What came of "Stop agent and its processes".
final class AgentStopResult {
  const AgentStopResult({required this.agent, this.reply, this.terminalOnly = false, this.error, this.computer});

  final String agent;

  /// The own computer that stopped it (`null`: this one).
  final String? computer;

  /// The daemon's account of the stop (`null`: it could not do it).
  final AgentStoppedReply? reply;

  /// The daemon could not stop it (an older daemon, or [error]): the window stopped its own terminal only.
  final bool terminalOnly;

  /// Why the daemon could not (`null`: it did, or an older daemon only lacks the command).
  final Object? error;
}

mixin AgentStopMixin on CodeMixin {
  /// The daemon's control protocol version (`hello_ok.proto`).
  int get daemonProto;

  /// The daemon stopped answering in the middle of a command.
  void daemonFailed(Object e);

  /// [run] started: its terminal session is the agent's.
  @override
  void codeRunStarted(AgentRun run) {
    super.codeRunStarted(run);
    registerTerminal(run);
  }

  /// Tell the daemon (again) where every live tab's agent runs: after a (re)connect, a daemon that restarted knows
  /// none of them.
  void registerAgentTerminals() {
    for (final r in liveRuns) {
      registerTerminal(r);
    }
  }

  /// `agent_terminal` for [run]: its agent runs in the session the wrapper [AgentRun.pid] leads. Errors are only
  /// logged: an older daemon has no such command, and a stop then takes what it can find without it. Not on Windows:
  /// there is no terminal session there, and the run's job (`antenna agent-run`) holds everything the agent started;
  /// the stop's `agent` event stops the tab ([onAgentStopped]).
  @protected
  void registerTerminal(AgentRun run) {
    final pid = run.pid;
    if (pid == null || !run.alive || daemonProto < 7 || (agentHost?.windows ?? false)) return;
    final agent = run.spec.agent;
    unawaited(daemon.agentTerminal(agent, pid).then((_) {}, onError: (Object e) {
      debugPrint('antenna/code: agent_terminal for "$agent" not noted: ${e is XControlException ? e.code : e}');
    }));
  }

  /// [name] runs now in a way a stop can take: a tab here, a process its token is bound to, or the link's wake agent
  /// in a run or a live session.
  bool agentRunsNow(String name) {
    if (runOf(name)?.alive ?? false) return true;
    final a = agents.where((x) => x.name == name).firstOrNull;
    if (a != null && AgentStatus.of(a).state == AgentLinkState.connected) return true;
    return wakeRules.any((r) =>
        r.agent == name && (r.running || (r.resident != null && r.resident!.state != ResidentState.sleeping)));
  }

  /// "Stop agent and its processes" for [agent] of this computer.
  Future<AgentStopResult> stopAgentAndProcesses(String agent) async {
    final run = runOf(agent);
    final tab = run != null && run.alive ? run : null;
    // Before the call: the sweep ends the tab's process while the daemon still works on the reply.
    tab?.markStopped();
    try {
      final r = await daemon.agentStop(agent);
      // Anything of its own terminal the daemon did not take, the window takes as before.
      if (tab != null && tab.alive) await stopRun(tab);
      unawaited(refreshAgents());
      return AgentStopResult(agent: agent, reply: r);
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) daemonFailed(e);
      final older = e is XControlException && e.code == XErrorCode.unknownCommand;
      if (tab != null) {
        await stopRun(tab);
        return AgentStopResult(agent: agent, terminalOnly: true, error: older ? null : e);
      }
      return AgentStopResult(agent: agent, error: e);
    }
  }

  /// "Stop agent and its processes" for [agent] of the own computer [computer] (its contact label): that computer
  /// stops it and reports what it took.
  Future<AgentStopResult> stopDeviceAgent(String computer, String agent) async {
    try {
      final r = await daemon.deviceAgentStop(computer, agent);
      return AgentStopResult(agent: agent, computer: computer, reply: r);
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) daemonFailed(e);
      return AgentStopResult(agent: agent, computer: computer, error: e);
    }
  }

  /// The `agent` event with `stopped` (CONTROL §33): the daemon stopped [AgentEvent.name] and its processes, asked
  /// here (`by: owner`) or by another own computer. A tab of it says so, and whatever is left of its terminal stops.
  void onAgentStopped(AgentEvent e) {
    if (e.change != 'stopped') return;
    final run = runOf(e.name);
    if (run == null) return;
    final by = e.by;
    run.markStopped(from: by == null || by == 'owner' ? null : by);
    if (run.alive) unawaited(stopRun(run));
    safeNotify();
  }
}
