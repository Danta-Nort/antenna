// SPDX-License-Identifier: AGPL-3.0-only
// Code mode agents restored after an automatic update (D-103, D-UI-29).
//
// When the daemon installs an update by itself, the installer closes the window (SIGTERM, so nothing of the window's
// own shutdown runs: the agents' terminals are hung up by the kernel) and opens it again; the new daemon comes up
// unlocked and says so in `status.updated`. The window then starts again every agent that ran in one of its terminals
// at that moment and has "Restore after an update" on (on by default): the same CLI in the same folder, in its own
// last session (`claude --resume <id>`, `codex resume <id>`), with the token file the daemon wrote for it (D-86) in its
// environment. Then it types one built-in line once the agent is idle: "Antenna was updated to <version>: read your
// inbox and continue." Nobody has signed in to the new window, so there is no owner subscription to wake the agent on
// new messages; for each restored Claude Code agent the window opens `agent_watch` instead, which gives it exactly the
// facts the agent itself gets (CONTROL §23), until the owner signs in.
//
// What the restore needs lives in the window settings file (`agent_runs`, appearance.dart): the CLI, the folder, the
// session ID the CLI's hooks or `notify` program recorded (a UUID, checked again on read), the token file's path (never
// the token), the switch, and whether the agent was running. `running` is set when the agent starts and cleared when
// its process ends while the window lives (the owner's Stop, the window's own quit question, the agent exiting); the
// installer's SIGTERM leaves it set. Nothing is restored while the daemon is locked, without `status.updated`, for an
// agent started after the update came up, or twice for one update.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../host/code_hooks.dart' show validSessionId;
import '../protocol/x_control.dart';
import 'agent_launch.dart';
import 'appearance.dart';
import 'code_mode.dart';
import 'code_wake.dart';

/// Why an agent is not restored (the window's log; `null` from [restoreRefusal]: it is).
enum RestoreRefusal {
  notRunning,
  switchedOff,
  ownCommand,
  noSession,
  startedAfterUpdate,
  alreadyRestored,
  noTokenFile,
  noFolder,
  alreadyRunning,
}

/// One `agent_runs` entry as the restore reads it.
final class RestoreRecord {
  const RestoreRecord({
    required this.agent,
    this.spec,
    this.session,
    this.tokenFile,
    this.restore = true,
    this.running = false,
    this.startedMs,
    this.restoredMs,
  });

  factory RestoreRecord.of(String agent, Map<String, Object?>? j) => RestoreRecord(
        agent: agent,
        spec: AgentRunSpec.fromJson(agent, j),
        session: validSessionId(j?['session'] is String ? j!['session']! as String : null),
        tokenFile: j?['token_file'] is String ? j!['token_file']! as String : null,
        restore: j?['restore'] != false,
        running: j?['running'] == true,
        startedMs: j?['started_ms'] is int ? j!['started_ms']! as int : null,
        restoredMs: j?['restored_ms'] is int ? j!['restored_ms']! as int : null,
      );

  final String agent;
  final AgentRunSpec? spec;
  final String? session;
  final String? tokenFile;
  final bool restore;
  final bool running;
  final int? startedMs;
  final int? restoredMs;
}

/// The token file's path as the window may hand it to a CLI: absolute, the daemon's own name for the agent's file
/// (`…/agents/<agent>.token`, D-86), a regular file that exists. The window never reads it.
bool plausibleTokenFile(String? path, String agent, {bool Function(String path)? isFile}) {
  if (path == null || !path.startsWith('/') || path.contains('/../') || !path.endsWith('/agents/$agent.token')) {
    return false;
  }
  return (isFile ?? (p) => FileSystemEntity.typeSync(p, followLinks: false) == FileSystemEntityType.file)(path);
}

/// Whether [r] is restored after the update [up] (`null`), or why not. [alive]: the agent runs in this window already.
RestoreRefusal? restoreRefusal(RestoreRecord r, UpdatedInfo up,
    {required bool alive, required bool Function(String dir) folderExists, bool Function(String path)? isFile}) {
  final spec = r.spec;
  if (!r.running) return RestoreRefusal.notRunning;
  if (!r.restore) return RestoreRefusal.switchedOff;
  if (spec == null || spec.cli == AgentCli.custom) return RestoreRefusal.ownCommand;
  if (r.session == null) return RestoreRefusal.noSession;
  // It must have been running when the window went away for this update, not started since (a later window crash).
  final started = r.startedMs;
  if (started == null || started >= up.atMs) return RestoreRefusal.startedAfterUpdate;
  if (r.restoredMs == up.atMs) return RestoreRefusal.alreadyRestored;
  if (!plausibleTokenFile(r.tokenFile, r.agent, isFile: isFile)) return RestoreRefusal.noTokenFile;
  if (!folderExists(spec.workDir)) return RestoreRefusal.noFolder;
  if (alive) return RestoreRefusal.alreadyRunning;
  return null;
}

/// An `agent_watch` the window holds for a restored agent while nobody has signed in.
class _Watch {
  _Watch(this.run);
  final AgentRun run;
  XDialog? dialog;
  Timer? retry;
  int attempts = 0;

  /// The daemon confirmed the subscription (`subscribed`).
  bool active = false;
  bool closed = false;

  void close() {
    closed = true;
    retry?.cancel();
    retry = null;
    final d = dialog;
    dialog = null;
    active = false;
    if (d != null) unawaited(d.cancel());
  }
}

mixin CodeRestoreMixin on CodeWakeMixin {
  StatusReply? get status;

  /// The daemon's control protocol version (`hello_ok.proto`).
  int get daemonProto;

  /// The window has no owner session while the keys are unlocked (signed out, or just restarted by an update): the
  /// only time `agent_watch` is used.
  bool get watchWithoutSession;

  /// The window settings file (`null`: none, as in most tests).
  AgentRunStore? agentRunStore;

  /// Restore after an update is possible with this daemon: it can install updates by itself (x-control/7).
  bool get restoreCapable => daemonProto >= 7;

  final Map<String, _Watch> _watches = {};

  /// Agents restored after the update the window last saw (for the sign-in screen), in order.
  final List<String> restoredAgents = [];

  /// The version they were restored after.
  String? restoredVersion;

  /// "Restore after an update" for [agent] (on by default; window.json `agent_runs[agent].restore`).
  bool codeRestoreOn(String agent) => agentRunStore?.agentRunRecord(agent)?['restore'] != false;

  void setCodeRestore(String agent, bool on) {
    final store = agentRunStore;
    if (store == null || codeRestoreOn(agent) == on) return;
    store.patchAgentRun(agent, {'restore': on ? null : false});
    safeNotify();
  }

  @override
  bool wantsTokenFile(String agent, AgentCli cli) =>
      agentRunStore != null && restoreCapable && cli != AgentCli.custom && codeRestoreOn(agent);

  @override
  void codeRunStarted(AgentRun run) {
    super.codeRunStarted(run);
    final s = run.spec;
    agentRunStore?.patchAgentRun(s.agent, {
      'cli': s.cli.name,
      'dir': s.workDir,
      'cmd': s.command.isEmpty ? null : s.command,
      'running': true,
      'started_ms': now().millisecondsSinceEpoch,
      'token_file': run.tokenFile,
      // A fresh start is a new conversation; a restored one keeps its session until the CLI reports one.
      'session': run.tokenFile == null ? null : run.sessionId,
    });
  }

  @override
  void codeRunEnded(AgentRun run) {
    super.codeRunEnded(run);
    agentRunStore?.patchAgentRun(run.spec.agent, {'running': null});
    _closeWatch(run.spec.agent);
  }

  @override
  void codeSessionRecorded(AgentRun run, String id) {
    super.codeSessionRecorded(run, id);
    // Kept only for an agent that can be restored (it runs with a token file): nothing else needs it.
    if (run.tokenFile != null) agentRunStore?.patchAgentRun(run.spec.agent, {'session': id});
  }

  /// After the window read `status`: when this daemon came up from an automatic update and its keys are unlocked,
  /// start again every agent that qualifies ([restoreRefusal]), each at most once per update.
  void restoreAfterUpdate() {
    final st = status;
    final up = st?.updated;
    final store = agentRunStore;
    final host = agentHost;
    if (st == null || up == null || st.state != DaemonState.unlocked || store == null || host == null) return;
    if (binaries?.cli == null) return;
    for (final agent in store.agentRunNames.toList()) {
      final r = RestoreRecord.of(agent, store.agentRunRecord(agent));
      final why = restoreRefusal(r, up,
          alive: runOf(agent)?.alive ?? false, folderExists: host.folderExists, isFile: host.isFile);
      if (why != null) {
        if (r.running) debugPrint('antenna/code: not restoring "$agent" after the update: ${why.name}');
        continue;
      }
      // Recorded first: a window that dies during the start does not start it again for this update.
      store.patchAgentRun(agent, {'restored_ms': up.atMs});
      final result = launchRestored(r.spec!, tokenFile: r.tokenFile!, sessionId: r.session!);
      if (result is! AgentRun) {
        debugPrint('antenna/code: restoring "$agent" failed: $result');
        continue;
      }
      result.restoredTo = up.to;
      debugPrint('antenna/code: restored "$agent" (${r.spec!.cli.name}) after the update to ${sanitizeVersion(up.to)}');
      if (!restoredAgents.contains(agent)) restoredAgents.add(agent);
      restoredVersion = up.to;
      queueUpdateLine(result, up.to);
    }
    syncAgentWatches();
    safeNotify();
  }

  /// Open `agent_watch` for every restored Claude Code agent while the window has no owner session, and close them
  /// all once it has one (the owner subscription wakes them then) or the agent stopped. None on Windows: automatic
  /// updates come there with D-134, and the restore after one with them.
  void syncAgentWatches() {
    final wanted = <String>{
      if (watchWithoutSession && !(agentHost?.windows ?? false))
        for (final r in liveRuns)
          if (r.restoredTo != null && r.spec.cli.wakes && codeWakeOn(r.spec.agent) && !r.watchUnavailable)
            r.spec.agent,
    };
    for (final a in _watches.keys.toList()) {
      if (!wanted.contains(a)) _closeWatch(a);
    }
    for (final a in wanted) {
      if (_watches.containsKey(a)) continue;
      final run = runOf(a);
      if (run == null) continue;
      if (daemonProto < 7) {
        run.watchUnavailable = true;
        continue;
      }
      final w = _watches[a] = _Watch(run);
      _openWatch(w);
    }
  }

  /// The window watches [agent]'s facts now (`subscribed` arrived).
  bool watchingAgent(String agent) => _watches[agent]?.active ?? false;

  void _openWatch(_Watch w) {
    if (w.closed) return;
    final agent = w.run.spec.agent;
    final d = w.dialog = daemon.agentWatch(agent);
    d.events.listen((e) {
      if (w.closed || !identical(w.dialog, d)) return;
      switch (e) {
        case Subscribed():
          w
            ..active = true
            ..attempts = 0;
          debugPrint('antenna/code: watching "$agent" without a session (agent_watch)');
          safeNotify();
        case MessageFactEvent(:final contact, :final id, :final urgent):
          onCodeFact(w.run, contact, id: id, urgent: urgent);
        // A request waits for this approver's answer (CONTROL §31): facts only
        case ApprovalToAnswerEvent(:final id, :final device):
          onCodeToAnswerRun(w.run, '${device ?? ''}/$id');
        default:
          break;
      }
    });
    d.result.then((_) => _watchEnded(w, d, null), onError: (Object e) => _watchEnded(w, d, e));
  }

  /// The watch ended: an older daemon or a lock end it for good; anything else (the agent's MCP server not bound yet,
  /// its binding ended, the daemon restarting) is tried again while it is still wanted, a little later each time.
  void _watchEnded(_Watch w, XDialog d, Object? e) {
    if (w.closed || !identical(w.dialog, d)) return;
    w
      ..dialog = null
      ..active = false;
    final code = e is XControlException ? e.code : null;
    if (code == XErrorCode.unknownCommand || code == XErrorCode.notImplemented) {
      w.run.watchUnavailable = true;
      _closeWatch(w.run.spec.agent);
      debugPrint('antenna/code: the daemon has no agent_watch: no wake before sign-in');
      safeNotify();
      return;
    }
    if (code == XErrorCode.locked) {
      _closeWatch(w.run.spec.agent);
      safeNotify();
      return;
    }
    final delay = Duration(seconds: [2, 4, 8, 15, 30][w.attempts.clamp(0, 4)]);
    w.attempts++;
    w.retry = Timer(delay, () {
      w.retry = null;
      if (!w.closed && w.run.alive && watchWithoutSession) _openWatch(w);
    });
    safeNotify();
  }

  void _closeWatch(String agent) => _watches.remove(agent)?.close();

  /// The window goes away (or the model does).
  void closeAgentWatches() {
    for (final w in _watches.values) {
      w.close();
    }
    _watches.clear();
  }
}
