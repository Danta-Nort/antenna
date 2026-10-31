// SPDX-License-Identifier: AGPL-3.0-only
// Local models and local agents (x-control/7, CONTROL §24; docs/LOCAL-ASSISTANT.md §7). A model is a file on this
// computer the daemon downloads and checks; a local agent is an ordinary agent of this node that the daemon runs on
// a ready model, in its own sandbox, with its own conversation (several agents may share one model). The window owns
// none of it: the catalog, the computer, every state and every conversation come from `local_models`,
// `local_history`, the `local_model` / `local_agent` events and the `local_say` dialog. A daemon older than v7 gets
// none of these commands.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'owner_auth.dart';

final _agentName = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// A name the daemon accepts for an agent (`[A-Za-z0-9._-]{1,64}`).
bool validLocalAgentName(String name) => _agentName.hasMatch(name);

/// A free agent name made from a model's catalog ID (`qwen3.5-2b`, then `qwen3.5-2b-2`, …).
String suggestLocalAgentName(String modelId, Iterable<String> taken) {
  var base = modelId.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) base = 'local';
  if (base.length > 60) base = base.substring(0, 60);
  final used = taken.toSet();
  if (!used.contains(base)) return base;
  for (var i = 2;; i++) {
    final n = '$base-$i';
    if (!used.contains(n)) return n;
  }
}

// C0 and C1 controls (except tab and newline) and the bidirectional overrides: a model's text could otherwise hide
// or reorder what the owner reads (docs/LOCAL-ASSISTANT.md §6.3 R1, R9).
final _controls = RegExp(r'[\x00-\x08\x0B-\x1F\x7F-\x9F\u200E\u200F\u202A-\u202E\u2066-\u2069]');

/// A model's text as the window shows it: plain text, control characters removed. Nothing in it is a link or markup.
String plainModelText(String s) => s.replaceAll('\r\n', '\n').replaceAll(_controls, '');

/// The reply being written in this window's `local_say`.
class LocalLiveTurn {
  LocalLiveTurn(this.startedAt);
  final DateTime startedAt;

  /// The turn's number, from the first `local_delta`.
  int? turn;
  String text = '';

  /// `loading` (the model is being loaded) or `waiting` (for memory); `null` while text streams.
  String? activity;

  /// The owner pressed Stop (`local_session interrupt`); the daemon ends the turn.
  bool stopping = false;
}

/// One local agent's conversation as the window shows it.
class LocalConversation {
  /// From `local_history`, oldest first.
  List<LocalItem> items = const [];
  bool loaded = false;

  /// Older messages exist.
  bool more = false;
  bool loadingOlder = false;

  /// The owner's message of the turn in progress, until `local_history` has it.
  String? pending;
  DateTime? pendingAt;
  LocalLiveTurn? live;

  /// Why a turn failed (`local_turn.detail`), by turn: `local_history` does not keep it.
  final Map<int, String> failures = {};

  /// The last `local_say` that the daemon refused (no model, no session, …).
  Object? error;
}

mixin LocalModelsMixin on ChangeNotifier {
  XDaemon get daemon;
  HelloOk? get hello;
  DateTime now();

  /// Notify the window (no error after dispose).
  void safeNotify();
  Future<void> refreshAgents();

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);

  /// The link conversation on screen; a local agent's conversation replaces it.
  String? get selectedLinkId;
  set selectedLinkId(String? linkId);

  /// The daemon speaks x-control/7 and answers `local_models`: local models exist for this window. An older one gets
  /// none of the commands, and the window shows nothing of them.
  bool get localModelsSupported => controlVersion(hello?.proto) >= localModelsVersion && !localModelsAbsent;

  /// A v7 daemon refused `local_models` as an unknown command: one built before local models (x-control/7 also
  /// carries owner keys and updates). The window then treats it like an older daemon until it reconnects.
  bool localModelsAbsent = false;

  /// The computer and the runtime as the daemon reads them; `null` until `local_models` answered.
  HardwareInfo? localHardware;
  LocalRuntimeInfo? localRuntime;

  /// This release's catalog, smallest first, each model with its state here.
  List<LocalModelInfo> localModels = const [];
  List<LocalAgentInfo> localAgents = const [];

  /// The last `local_models` failed (shown on the card).
  Object? localError;

  /// The local agent whose conversation is on screen.
  String? selectedLocalAgent;
  final Map<String, LocalConversation> localChats = {};

  LocalModelInfo? localModel(String id) => localModels.where((m) => m.id == id).firstOrNull;
  LocalAgentInfo? localAgent(String name) => localAgents.where((a) => a.name == name).firstOrNull;
  LocalConversation localChatOf(String agent) => localChats.putIfAbsent(agent, LocalConversation.new);

  /// The computer the models run on is a Mac (the daemon's word; the window's own platform before it answered).
  bool get localOnMac => localHardware?.macos ?? defaultTargetPlatform == TargetPlatform.macOS;

  Future<void> refreshLocalModels() async {
    if (!localModelsSupported) return;
    try {
      final r = await daemon.localModels();
      localHardware = r.hardware;
      localRuntime = r.runtime;
      localModels = r.models;
      final before = {for (final a in localAgents) a.name: a};
      localAgents = r.agents;
      localError = null;
      if (selectedLocalAgent != null && localAgent(selectedLocalAgent!) == null) selectedLocalAgent = null;
      for (final a in r.agents) {
        _afterAgentChange(before[a.name], a);
      }
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand ||
          (e.code == XErrorCode.badRequest && e.message.contains('unknown variant'))) {
        localModelsAbsent = true;
      } else {
        localError = e;
      }
    } on XClientException catch (e) {
      localError = e;
    }
    safeNotify();
  }

  void clearLocal() {
    localModelsAbsent = false;
    localHardware = null;
    localRuntime = null;
    localModels = const [];
    localAgents = const [];
    localError = null;
    selectedLocalAgent = null;
    localChats.clear();
  }

  /// A `local_model` or `local_agent` event.
  void onLocalEvent(XEvent e) {
    switch (e) {
      case LocalModelEvent(:final model):
        final i = localModels.indexWhere((m) => m.id == model.id);
        localModels = i < 0 ? [...localModels, model] : ([...localModels]..[i] = model);
      case LocalAgentEvent(:final agent):
        final i = localAgents.indexWhere((a) => a.name == agent.name);
        final before = i < 0 ? null : localAgents[i];
        localAgents = i < 0 ? [...localAgents, agent] : ([...localAgents]..[i] = agent);
        // A new local agent is also a new agent of this node.
        if (before == null) unawaited(refreshAgents());
        _afterAgentChange(before, agent);
      default:
        return;
    }
    safeNotify();
  }

  /// A turn ended somewhere (this window, the CLI, another window): an open conversation reads its history again,
  /// unless this window's own `local_say` is still waiting for it (it reads the history when the turn reply comes).
  void _afterAgentChange(LocalAgentInfo? before, LocalAgentInfo now) {
    final c = localChats[now.name];
    if (c == null || !c.loaded || c.live != null) return;
    if (before != null && before.turns != now.turns) unawaited(loadLocalHistory(now.name));
  }

  /// Download a model (or take [fromFile]). Returns the daemon's error or `null`.
  Future<Object?> installLocalModel(String id, {String? fromFile}) async {
    try {
      _putModel(await daemon.modelInstall(id, fromFile: fromFile));
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// Cancel a download or delete the model's file; its agents stay. Returns the daemon's error or `null`.
  Future<Object?> removeLocalModel(String id) async {
    try {
      _putModel(await daemon.modelRemove(id));
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  void _putModel(LocalModelInfo m) {
    final i = localModels.indexWhere((x) => x.id == m.id);
    localModels = i < 0 ? [...localModels, m] : ([...localModels]..[i] = m);
    safeNotify();
  }

  /// Create a local agent on [model] (owner password, never stored). Returns the agent, or the daemon's error.
  Future<(LocalAgentInfo?, Object?)> addLocalAgent(String name, String model, OwnerAuth auth) async {
    try {
      final a = await ownerOp(auth, (d, pw) => d.localAgentAdd(name, model: model, password: pw));
      final i = localAgents.indexWhere((x) => x.name == a.name);
      localAgents = i < 0 ? [...localAgents, a] : ([...localAgents]..[i] = a);
      safeNotify();
      unawaited(refreshAgents());
      unawaited(refreshLocalModels());
      return (a, null);
    } on XClientException catch (e) {
      return (null, e);
    }
  }

  /// Remove a local agent with its conversation (`agent_remove`, owner password).
  Future<Object?> removeLocalAgent(String name, OwnerAuth auth) async {
    try {
      await ownerOp(auth, (d, pw) => d.agentRemove(name, pw));
      localChats.remove(name);
      if (selectedLocalAgent == name) selectedLocalAgent = null;
      localAgents = localAgents.where((a) => a.name != name).toList();
      safeNotify();
      unawaited(refreshAgents());
      unawaited(refreshLocalModels());
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// Open a local agent's conversation in place of a link's.
  Future<void> selectLocalAgent(String name) async {
    selectedLocalAgent = name;
    selectedLinkId = null;
    safeNotify();
    final c = localChatOf(name);
    if (!c.loaded) await loadLocalHistory(name);
  }

  /// The conversation's latest page, or the page before the one shown ([older]).
  Future<void> loadLocalHistory(String agent, {bool older = false}) async {
    final c = localChatOf(agent);
    if (older && (c.loadingOlder || !c.more || c.items.isEmpty)) return;
    if (older) c.loadingOlder = true;
    try {
      final r = await daemon.localHistory(agent, limit: 100, before: older ? c.items.first.seq : null);
      if (older) {
        c.items = [...r.items, ...c.items];
      } else {
        c.items = r.items;
      }
      c.more = r.more;
      c.loaded = true;
    } on XClientException catch (e) {
      if (!older) c.error = e;
    } finally {
      c.loadingOlder = false;
      safeNotify();
    }
  }

  /// The owner writes to a local agent: the reply streams into the live turn, then the conversation is read again.
  /// Returns the daemon's error (the owner's text did not go) or `null`.
  Future<Object?> sayLocal(String agent, String text) async {
    final c = localChatOf(agent);
    if (c.live != null) return null;
    c
      ..error = null
      ..pending = text
      ..pendingAt = now()
      ..live = LocalLiveTurn(now());
    safeNotify();
    final d = daemon.localSay(agent, text);
    final sub = d.events.listen((e) {
      final live = c.live;
      if (e is! LocalDeltaEvent || e.agent != agent || live == null) return;
      live.turn = e.turn;
      live.text += e.delta;
      live.activity = e.delta.isEmpty ? e.activity : null;
      safeNotify();
    });
    Object? error;
    try {
      final r = await d.result;
      if (r is LocalTurnReply && r.outcome == 'failed') c.failures[r.turn] = r.detail;
    } on XClientException catch (e) {
      error = e;
      c.error = e;
    }
    // The turn's two messages are in the daemon's history now (also after most refusals, nothing is lost by asking).
    // Deltas still queued behind the reply only reach the live turn until the history replaces it.
    await loadLocalHistory(agent);
    // Not awaited: a single-subscription cancel completes in the root zone, which a test's fake clock never runs.
    unawaited(sub.cancel());
    c
      ..live = null
      ..pending = null
      ..pendingAt = null;
    safeNotify();
    return error;
  }

  /// End the turn in progress; its reply so far stays, marked interrupted.
  Future<Object?> interruptLocal(String agent) async {
    final live = localChats[agent]?.live;
    if (live != null) live.stopping = true;
    safeNotify();
    return _session(agent, LocalSessionAction.interrupt);
  }

  /// Start a new conversation: the daemon deletes the old one.
  Future<Object?> resetLocal(String agent) async {
    final err = await _session(agent, LocalSessionAction.reset);
    if (err == null) {
      final c = localChatOf(agent);
      c
        ..items = const []
        ..more = false
        ..error = null
        ..failures.clear();
      await loadLocalHistory(agent);
    }
    return err;
  }

  Future<Object?> _session(String agent, String action) async {
    try {
      final a = await daemon.localSession(agent, action);
      final i = localAgents.indexWhere((x) => x.name == a.name);
      if (i >= 0) localAgents = [...localAgents]..[i] = a;
      safeNotify();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }
}
