// SPDX-License-Identifier: AGPL-3.0-only
// Local models and local agents (x-control/7, CONTROL §24; crates/antenna-proto/src/control/local.rs): a part of
// models.dart, which holds the shared parsing helpers. A model's and an agent's text in a conversation is the model's
// output: it never reaches `toString`, and the window shows it as plain text.

part of 'models.dart';

int _int0(Json j, String k) => _optInt(j, k) ?? 0;

/// How a catalog model suits this computer (`LocalModelInfo.fit`).
abstract final class LocalFit {
  /// The one model the daemon suggests here (exactly one, or none).
  static const recommended = 'recommended';
  static const fits = 'fits';

  /// Fits in memory, but answers slowly on this computer.
  static const slow = 'slow';

  /// Needs more memory than local models may use now.
  static const tooBig = 'too_big';

  /// This computer runs no local model: below 8 GB of memory, or an x86-64 CPU without AVX2.
  static const unsupported = 'unsupported';
}

/// A catalog model's state on this computer (`LocalModelInfo.state`).
abstract final class LocalModelState {
  /// Not on this computer.
  static const available = 'available';
  static const downloading = 'downloading';

  /// The last byte is in; the size and the SHA-256 are being checked.
  static const verifying = 'verifying';
  static const ready = 'ready';

  /// See `LocalModelInfo.errorCode`.
  static const failed = 'failed';
}

/// A local agent's state (`LocalAgentInfo.state`).
abstract final class LocalAgentState {
  /// No process.
  static const sleeping = 'sleeping';

  /// For memory: another model has to unload first.
  static const waiting = 'waiting';

  /// Its model is being loaded.
  static const loading = 'loading';
  static const idle = 'idle';

  /// A turn is running.
  static const busy = 'busy';

  /// The next turn tries again.
  static const failed = 'failed';

  /// Its model is not on this computer.
  static const noModel = 'no_model';
}

/// The computer as the daemon reads it, without any permission or prompt.
final class HardwareInfo {
  const HardwareInfo({
    required this.os,
    required this.arch,
    required this.cpu,
    required this.cores,
    required this.threads,
    this.avx2 = false,
    required this.accel,
    required this.memoryBytes,
    required this.availableBytes,
    required this.budgetBytes,
    required this.diskFreeBytes,
  });

  factory HardwareInfo.fromJson(Json j) => HardwareInfo(
        os: _optStr(j, 'os') ?? '',
        arch: _optStr(j, 'arch') ?? '',
        cpu: _optStr(j, 'cpu') ?? '',
        cores: _int0(j, 'cores'),
        threads: _int0(j, 'threads'),
        avx2: _bool(j, 'avx2'),
        accel: _optStr(j, 'accel') ?? '',
        memoryBytes: _int0(j, 'memory_bytes'),
        availableBytes: _int0(j, 'available_bytes'),
        budgetBytes: _int0(j, 'budget_bytes'),
        diskFreeBytes: _int0(j, 'disk_free_bytes'),
      );

  /// `linux`, `macos`.
  final String os;

  /// `x86_64`, `aarch64`.
  final String arch;

  /// The CPU's name; empty when unknown.
  final String cpu;
  final int cores;
  final int threads;
  final bool avx2;

  /// `metal` (Apple silicon GPU) or `cpu`.
  final String accel;
  final int memoryBytes;
  final int availableBytes;

  /// What local models may use now.
  final int budgetBytes;

  /// Free space on the disk that holds the models.
  final int diskFreeBytes;

  bool get macos => os == 'macos';
}

/// The runtime this daemon starts models with.
final class LocalRuntimeInfo {
  const LocalRuntimeInfo({required this.available, this.version = '', this.sandbox = '', this.detail = ''});

  factory LocalRuntimeInfo.fromJson(Json j) => LocalRuntimeInfo(
        available: _bool(j, 'available'),
        version: _optStr(j, 'version') ?? '',
        sandbox: _optStr(j, 'sandbox') ?? '',
        detail: _optStr(j, 'detail') ?? '',
      );

  /// The runtime and its sandbox are there: models can run. Models can be downloaded either way.
  final bool available;

  /// `llama.cpp v0.6.0`; empty when missing.
  final String version;

  /// `bwrap`, `landlock`, `seatbelt`, `none`.
  final String sandbox;

  /// When not available: why (the daemon's English text); otherwise what the sandbox closes.
  final String detail;
}

/// One model of the catalog and its state on this computer.
final class LocalModelInfo {
  const LocalModelInfo({
    required this.id,
    required this.name,
    required this.maker,
    required this.license,
    required this.licenseUrl,
    this.languages = '',
    this.params = '',
    this.quant = '',
    required this.sizeBytes,
    required this.memoryBytes,
    this.context = 0,
    this.source = '',
    required this.fit,
    this.fitDetail = '',
    this.estTokensPerS,
    required this.state,
    this.doneBytes = 0,
    this.speedBytesPerS,
    this.errorCode,
    this.error,
    this.loaded = false,
    this.agents = const [],
  });

  factory LocalModelInfo.fromJson(Json j) => LocalModelInfo(
        id: _str(j, 'id'),
        name: _optStr(j, 'name') ?? _str(j, 'id'),
        maker: _optStr(j, 'maker') ?? '',
        license: _optStr(j, 'license') ?? '',
        licenseUrl: _optStr(j, 'license_url') ?? '',
        languages: _optStr(j, 'languages') ?? '',
        params: _optStr(j, 'params') ?? '',
        quant: _optStr(j, 'quant') ?? '',
        sizeBytes: _int0(j, 'size_bytes'),
        memoryBytes: _int0(j, 'memory_bytes'),
        context: _int0(j, 'context'),
        source: _optStr(j, 'source') ?? '',
        fit: _optStr(j, 'fit') ?? LocalFit.fits,
        fitDetail: _optStr(j, 'fit_detail') ?? '',
        estTokensPerS: _optInt(j, 'est_tokens_per_s'),
        state: _optStr(j, 'state') ?? LocalModelState.available,
        doneBytes: _int0(j, 'done_bytes'),
        speedBytesPerS: _optInt(j, 'speed_bytes_per_s'),
        errorCode: _optStr(j, 'error_code'),
        error: _optStr(j, 'error'),
        loaded: _bool(j, 'loaded'),
        agents: _strList(j, 'agents'),
      );

  /// Catalog ID (`qwen3.5-2b`).
  final String id;
  final String name;

  /// Who made the weights.
  final String maker;

  /// SPDX license of the weights, and its text.
  final String license;
  final String licenseUrl;
  final String languages;
  final String params;
  final String quant;

  /// Download size.
  final int sizeBytes;

  /// Memory in use on this computer with one conversation.
  final int memoryBytes;

  /// Context per conversation, tokens.
  final int context;

  /// `huggingface.co/<repo>@<commit>/<file>`.
  final String source;

  /// [LocalFit].
  final String fit;

  /// The facts behind [fit], in English (the window shows its own words by [fit]).
  final String fitDetail;

  /// Expected generation speed here (an estimate); `null` when unknown.
  final int? estTokensPerS;

  /// [LocalModelState].
  final String state;

  /// Downloading: bytes on disk so far; verifying: bytes checked.
  final int doneBytes;

  /// Downloading only.
  final int? speedBytesPerS;

  /// Failed: `hash_mismatch`, `no_space`, `fetch_failed`, `sandbox_unavailable`, …
  final String? errorCode;

  /// Failed: what happened (the daemon's English text).
  final String? error;

  /// The runtime holds it in memory now.
  final bool loaded;

  /// Local agents that run on it.
  final List<String> agents;

  bool get ready => state == LocalModelState.ready;

  /// The download host, for the owner (`huggingface.co`).
  String get host {
    final s = source;
    final i = s.indexOf('/');
    return i < 0 ? s : s.substring(0, i);
  }

  @override
  String toString() => 'LocalModelInfo($id, $state, $fit)';
}

/// Tokens and time of one turn, as the runtime reports them.
final class LocalUsage {
  const LocalUsage({
    required this.promptTokens,
    this.cachedTokens = 0,
    required this.outputTokens,
    this.promptMs = 0,
    this.outputMs = 0,
  });

  factory LocalUsage.fromJson(Json j) => LocalUsage(
        promptTokens: _int0(j, 'prompt_tokens'),
        cachedTokens: _int0(j, 'cached_tokens'),
        outputTokens: _int0(j, 'output_tokens'),
        promptMs: _int0(j, 'prompt_ms'),
        outputMs: _int0(j, 'output_ms'),
      );

  final int promptTokens;
  final int cachedTokens;
  final int outputTokens;
  final int promptMs;
  final int outputMs;
}

LocalUsage? _usage(Json j, String k) => j[k] is Map<String, Object?> ? LocalUsage.fromJson(_obj(j, k)) : null;

/// A local agent: an agent of this node whose program the daemon runs with a local model.
final class LocalAgentInfo {
  const LocalAgentInfo({
    required this.name,
    required this.model,
    required this.runtime,
    required this.state,
    this.detail = '',
    this.turns = 0,
    this.lastTurnMs,
    this.lastUsage,
    this.createdMs = 0,
  });

  factory LocalAgentInfo.fromJson(Json j) => LocalAgentInfo(
        name: _str(j, 'name'),
        model: _optStr(j, 'model') ?? '',
        runtime: _optStr(j, 'runtime') ?? '',
        state: _optStr(j, 'state') ?? LocalAgentState.sleeping,
        detail: _optStr(j, 'detail') ?? '',
        turns: _int0(j, 'turns'),
        lastTurnMs: _optInt(j, 'last_turn_ms'),
        lastUsage: _usage(j, 'last_usage'),
        createdMs: _int0(j, 'created_ms'),
      );

  final String name;

  /// Catalog ID of its model.
  final String model;

  /// `local`: this daemon launched the runtime itself. The "Local" badge is shown only for this value (D-96 §7.5).
  final String runtime;

  /// [LocalAgentState].
  final String state;

  /// The facts behind the state (a failure's reason, what it waits for), the daemon's English text.
  final String detail;

  /// Turns so far, all conversations.
  final int turns;
  final int? lastTurnMs;
  final LocalUsage? lastUsage;
  final int createdMs;

  /// The daemon runs this agent's model itself, on this computer.
  bool get runsHere => runtime == 'local';

  @override
  String toString() => 'LocalAgentInfo($name, $model, $state)';
}

/// One message of a local agent's conversation, kept in the node's encrypted database.
final class LocalItem {
  const LocalItem({
    required this.seq,
    required this.turn,
    required this.role,
    required this.text,
    required this.tsMs,
    this.outcome,
    this.detail = '',
    this.usage,
  });

  factory LocalItem.fromJson(Json j) => LocalItem(
        seq: _int(j, 'seq'),
        turn: _int0(j, 'turn'),
        role: _str(j, 'role'),
        text: _optStr(j, 'text') ?? '',
        tsMs: _int0(j, 'ts_ms'),
        outcome: _optStr(j, 'outcome'),
        detail: _optStr(j, 'detail') ?? '',
        usage: _usage(j, 'usage'),
      );

  /// Order in the database.
  final int seq;
  final int turn;

  /// `owner` or `agent`.
  final String role;

  /// The text: the model's output for the agent's messages.
  final String text;
  final int tsMs;

  /// The agent's messages: `done`, `interrupted`, `failed`.
  final String? outcome;

  /// The agent's messages: why the turn failed or was interrupted (the daemon's English text), or empty. Kept with
  /// the message, so it is there after a restart too; older daemons do not send it.
  final String detail;
  final LocalUsage? usage;

  bool get byOwner => role == 'owner';

  @override
  String toString() => 'LocalItem($seq, $role, ${text.length} chars)';
}

/// `local_models`.
final class LocalModelsReply extends Reply {
  const LocalModelsReply({required this.hardware, required this.runtime, required this.models, required this.agents});

  factory LocalModelsReply.fromJson(Json j) => LocalModelsReply(
        hardware: HardwareInfo.fromJson(_obj(j, 'hardware')),
        runtime: LocalRuntimeInfo.fromJson(_obj(j, 'runtime')),
        models: [for (final m in _list(j, 'models')) LocalModelInfo.fromJson(m)],
        agents: [for (final a in _list(j, 'agents')) LocalAgentInfo.fromJson(a)],
      );

  final HardwareInfo hardware;
  final LocalRuntimeInfo runtime;

  /// This release's catalog, smallest first.
  final List<LocalModelInfo> models;
  final List<LocalAgentInfo> agents;
}

/// A model's state after `model_install` or `model_remove`.
final class LocalModelReply extends Reply {
  const LocalModelReply(this.model);
  final LocalModelInfo model;
}

/// A local agent after `local_agent_add` or `local_session`.
final class LocalAgentReply extends Reply {
  const LocalAgentReply(this.agent);
  final LocalAgentInfo agent;
}

/// The end of a local agent's turn (`local_say`).
final class LocalTurnReply extends Reply {
  const LocalTurnReply({
    required this.agent,
    required this.turn,
    required this.outcome,
    required this.text,
    this.detail = '',
    this.usage,
  });

  factory LocalTurnReply.fromJson(Json j) => LocalTurnReply(
        agent: _str(j, 'agent'),
        turn: _int0(j, 'turn'),
        outcome: _str(j, 'outcome'),
        text: _optStr(j, 'text') ?? '',
        detail: _optStr(j, 'detail') ?? '',
        usage: _usage(j, 'usage'),
      );

  final String agent;
  final int turn;

  /// `done`, `interrupted`, `failed`.
  final String outcome;

  /// The whole reply (what was generated before an interrupt or a failure).
  final String text;

  /// What went wrong (`failed`), the daemon's English text; or empty.
  final String detail;
  final LocalUsage? usage;

  @override
  String toString() => 'LocalTurnReply($agent, $turn, $outcome, ${text.length} chars)';
}

/// `local_history`: a page of a local agent's conversation, oldest first.
final class LocalHistoryReply extends Reply {
  const LocalHistoryReply({required this.agent, required this.items, this.more = false});

  factory LocalHistoryReply.fromJson(Json j) => LocalHistoryReply(
        agent: _str(j, 'agent'),
        items: [for (final i in _list(j, 'items')) LocalItem.fromJson(i)],
        more: _bool(j, 'more'),
      );

  final String agent;
  final List<LocalItem> items;

  /// Older messages exist (ask again with `before` = the first `seq`).
  final bool more;
}

/// A piece of a local agent's reply, only on the `local_say` connection that asked. An empty [delta] is an
/// [activity] change: `loading` (the model is being loaded), `waiting` (for memory); absent while text streams.
final class LocalDeltaEvent extends XEvent {
  const LocalDeltaEvent({required this.agent, required this.turn, required this.delta, this.activity});
  final String agent;
  final int turn;
  final String delta;
  final String? activity;

  @override
  String toString() => 'LocalDeltaEvent($agent, $turn, ${delta.length} chars, $activity)';
}

/// A catalog model's state changed (only to an `x-control/7` subscription): download progress, the check, loaded or
/// unloaded, removed.
final class LocalModelEvent extends XEvent {
  const LocalModelEvent(this.model);
  final LocalModelInfo model;
}

/// A local agent's state changed (only to an `x-control/7` subscription): loading, a turn started or ended, asleep,
/// failed. After a turn ends the window reads `local_history` again.
final class LocalAgentEvent extends XEvent {
  const LocalAgentEvent(this.agent);
  final LocalAgentInfo agent;
}
