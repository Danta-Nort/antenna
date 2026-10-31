// SPDX-License-Identifier: AGPL-3.0-only
// Whether an agent (and the AI app connected as it) is actually connected, from what the daemon knows: the process
// its token is bound to and whether that process still runs (`bound_*`), and the agent's last request
// (`last_seen_ms`). Pure Dart.

import '../protocol/x_control.dart';

enum AgentLinkState {
  /// The agent's MCP server is bound to a process that runs now.
  connected,

  /// The token was issued, but no app has called with it yet.
  waiting,

  /// The process the token was bound to has ended.
  disconnected,

  /// The agent made requests (a script, the CLI), but no MCP host is bound.
  seen,

  /// The agent is gone: an app's configuration still names it, but its token no longer works.
  revoked,
}

final class AgentStatus {
  const AgentStatus(this.state, {this.process, this.lastSeen, this.pid, this.sessions = 0});

  final AgentLinkState state;

  /// The bound process's name as the system reports it (`ChatGPT`, `claude`, `codex`, `Cursor Helper`…).
  final String? process;
  final int? pid;
  final DateTime? lastSeen;

  /// The app's MCP processes that run now as this agent (D-97); 0 when the daemon does not say.
  final int sessions;

  /// The status of [a]; `null` means the agent does not exist (any more).
  static AgentStatus of(AgentInfo? a) {
    if (a == null) return const AgentStatus(AgentLinkState.revoked);
    final seen = a.lastSeenMs == null ? null : DateTime.fromMillisecondsSinceEpoch(a.lastSeenMs!);
    final b = a.binding;
    if (b != null) {
      return AgentStatus(b.alive ? AgentLinkState.connected : AgentLinkState.disconnected,
          process: b.comm.isEmpty ? null : b.comm, pid: b.pid, lastSeen: seen, sessions: a.mcpProcesses ?? 0);
    }
    return AgentStatus(seen == null ? AgentLinkState.waiting : AgentLinkState.seen, lastSeen: seen);
  }
}

/// "just now", "2 min ago", "3 h ago", "2 days ago": the caller passes the localized forms.
String agoText(
  DateTime t,
  DateTime now, {
  required String justNow,
  required String Function(int) minutes,
  required String Function(int) hours,
  required String Function(int) days,
}) {
  final d = now.difference(t);
  if (d.inSeconds < 60) return justNow;
  if (d.inMinutes < 60) return minutes(d.inMinutes);
  if (d.inHours < 48) return hours(d.inHours);
  return days(d.inDays);
}
