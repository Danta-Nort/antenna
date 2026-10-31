// SPDX-License-Identifier: AGPL-3.0-only
// The fake daemon's local models and local agents (x-control/7, CONTROL §24). The catalog, the computer and the
// conversations are set by the test; `local_say` is a [FakeDialog] the test drives (deltas, then the turn), and
// `localReply` stores a turn's two messages the way the daemon does. A fake older than v7, or a v7 fake without
// [FakeLocalModels.localModelsEnabled] (a v7 daemon built before local models), refuses every command as an unknown
// variant, as the real daemon's strict parser does.

import 'package:antenna_desktop/protocol/x_control.dart';

import 'fake_daemon.dart' show FakeDialog;

/// Demo computers.
const demoMac = HardwareInfo(
  os: 'macos',
  arch: 'aarch64',
  cpu: 'Apple M2 Pro',
  cores: 8,
  threads: 12,
  accel: 'metal',
  memoryBytes: 16 * _gib,
  availableBytes: 9 * _gib,
  budgetBytes: 7 * _gib,
  diskFreeBytes: 210 * _gib,
);

const demoLinux = HardwareInfo(
  os: 'linux',
  arch: 'x86_64',
  cpu: 'AMD Ryzen 7 7840U',
  cores: 8,
  threads: 16,
  avx2: true,
  accel: 'cpu',
  memoryBytes: 32 * _gib,
  availableBytes: 20 * _gib,
  budgetBytes: 15 * _gib,
  diskFreeBytes: 140 * _gib,
);

/// Below 8 GB: no local model on this computer.
const demoSmallLaptop = HardwareInfo(
  os: 'linux',
  arch: 'x86_64',
  cpu: 'Intel Celeron N4020',
  cores: 2,
  threads: 2,
  avx2: false,
  accel: 'cpu',
  memoryBytes: 4 * _gib,
  availableBytes: 2 * _gib,
  budgetBytes: 1 * _gib,
  diskFreeBytes: 40 * _gib,
);

const _gib = 1024 * 1024 * 1024;

const demoRuntime = LocalRuntimeInfo(
  available: true,
  version: 'llama.cpp v0.6.0',
  sandbox: 'bwrap',
  detail: 'no network, one model file read-only',
);

/// The demo catalog (the shape of `packaging/models.json`, smallest first) with [fit] for each and the states given.
List<LocalModelInfo> demoCatalog({
  String smallFit = LocalFit.recommended,
  String smallState = LocalModelState.available,
  String mediumFit = LocalFit.fits,
  String largeFit = LocalFit.slow,
  String hugeFit = LocalFit.tooBig,
  int doneBytes = 0,
  int? speed,
  String? errorCode,
  String? error,
  List<String> smallAgents = const [],
}) =>
    [
      LocalModelInfo(
        id: 'qwen3.5-2b',
        name: 'Qwen3.5 2B',
        maker: 'Qwen (Alibaba Cloud)',
        license: 'Apache-2.0',
        licenseUrl: 'https://huggingface.co/Qwen/Qwen3.5-2B/blob/main/LICENSE',
        languages: '201 languages, English and Russian among them',
        params: '2.27B',
        quant: 'Q4_K_M',
        sizeBytes: 1280835840,
        memoryBytes: 2200000000,
        context: 8192,
        source: 'huggingface.co/unsloth/Qwen3.5-2B-GGUF@f6d5376be1ed/Qwen3.5-2B-Q4_K_M.gguf',
        fit: smallFit,
        estTokensPerS: 24,
        state: smallState,
        doneBytes: doneBytes,
        speedBytesPerS: speed,
        errorCode: errorCode,
        error: error,
        agents: smallAgents,
      ),
      LocalModelInfo(
        id: 'qwen3.5-4b',
        name: 'Qwen3.5 4B',
        maker: 'Qwen (Alibaba Cloud)',
        license: 'Apache-2.0',
        licenseUrl: 'https://huggingface.co/Qwen/Qwen3.5-4B/blob/main/LICENSE',
        params: '4B',
        quant: 'Q4_K_M',
        sizeBytes: 2740937888,
        memoryBytes: 4750000000,
        context: 8192,
        source: 'huggingface.co/unsloth/Qwen3.5-4B-GGUF@e87f176479d0/Qwen3.5-4B-Q4_K_M.gguf',
        fit: mediumFit,
        estTokensPerS: 13,
        state: LocalModelState.available,
      ),
      LocalModelInfo(
        id: 'gemma-3-12b',
        name: 'Gemma 3 12B',
        maker: 'Google',
        license: 'Gemma',
        licenseUrl: 'https://ai.google.dev/gemma/terms',
        params: '12B',
        quant: 'Q4_K_M',
        sizeBytes: 7300000000,
        memoryBytes: 9100000000,
        context: 8192,
        source: 'huggingface.co/unsloth/gemma-3-12b-it-GGUF@0d1e2f3a4b5c/gemma-3-12b-it-Q4_K_M.gguf',
        fit: largeFit,
        estTokensPerS: 4,
        state: LocalModelState.available,
      ),
      LocalModelInfo(
        id: 'qwen3.5-27b',
        name: 'Qwen3.5 27B',
        maker: 'Qwen (Alibaba Cloud)',
        license: 'Apache-2.0',
        licenseUrl: 'https://huggingface.co/Qwen/Qwen3.5-27B/blob/main/LICENSE',
        params: '27B',
        quant: 'Q4_K_M',
        sizeBytes: 16500000000,
        memoryBytes: 19800000000,
        context: 8192,
        source: 'huggingface.co/unsloth/Qwen3.5-27B-GGUF@1a2b3c4d5e6f/Qwen3.5-27B-Q4_K_M.gguf',
        fit: hugeFit,
        state: LocalModelState.available,
      ),
    ];

/// A local agent the daemon runs ([runtime] `local`).
LocalAgentInfo demoLocalAgent(String name,
        {String model = 'qwen3.5-2b', String state = LocalAgentState.idle, String detail = '', int turns = 0}) =>
    LocalAgentInfo(
      name: name,
      model: model,
      runtime: 'local',
      state: state,
      detail: detail,
      turns: turns,
      createdMs: DateTime(2026, 10, 2, 9).millisecondsSinceEpoch,
    );

mixin FakeLocalModels {
  // From FakeDaemon.
  List<String> get calls;
  int get protoVersion;
  String get password;

  /// A proof by an enrolled key was checked for the request being carried out (D-131): its password field is empty.
  bool get proofChecked;
  Map<String, String> get passwords;
  List<FakeDialog> get dialogs;
  List<AgentInfo> get agentList;
  set agentList(List<AgentInfo> v);

  /// This daemon has local models (with `protoVersion` 7). Off by default, so the frames and tests of other features
  /// on a v7 fake stay as they are.
  bool localModelsEnabled = false;

  HardwareInfo localHardware = demoMac;
  LocalRuntimeInfo localRuntime = demoRuntime;
  List<LocalModelInfo> localModelList = demoCatalog();
  List<LocalAgentInfo> localAgentList = [];

  /// Each local agent's conversation, oldest first.
  final localHistoryMap = <String, List<LocalItem>>{};

  /// `model_install` / `model_remove` / `local_session` / `local_agent_add` as the window sent them.
  final installCalls = <(String, String?)>[];
  final removeCalls = <String>[];
  final sessionCalls = <(String, String)>[];
  final localAgentAdds = <(String, String)>[];

  /// The `local_say` dialogs, in order, with what was said.
  final localSays = <(String, String, FakeDialog)>[];

  /// The next `model_install` fails with this error (`no_space`, …).
  XControlException? installError;
  int _localSeq = 0;

  void _v7(String cmd) {
    calls.add(cmd);
    if (protoVersion < 7 || !localModelsEnabled) {
      throw XControlException(XErrorCode.badRequest, 'bad message: unknown variant `$cmd`');
    }
  }

  LocalModelInfo _model(String id) => localModelList.firstWhere((m) => m.id == id,
      orElse: () => throw const XControlException(XErrorCode.notFound, 'no such model in this release'));

  LocalAgentInfo _agent(String name) => localAgentList.firstWhere((a) => a.name == name,
      orElse: () => throw const XControlException(XErrorCode.notFound, 'no such local agent'));

  /// Replace a model of the catalog (by ID) and return it.
  LocalModelInfo setLocalModel(String id, LocalModelInfo Function(LocalModelInfo m) change) {
    final i = localModelList.indexWhere((m) => m.id == id);
    final m = change(localModelList[i]);
    localModelList = [...localModelList]..[i] = m;
    return m;
  }

  LocalAgentInfo setLocalAgent(LocalAgentInfo a) {
    final i = localAgentList.indexWhere((x) => x.name == a.name);
    localAgentList = i < 0 ? [...localAgentList, a] : ([...localAgentList]..[i] = a);
    return a;
  }

  /// Store a turn the way the daemon does: the owner's message and the agent's reply.
  void localReply(String agent, String said, String reply, {String outcome = 'done', String detail = '', DateTime? at}) {
    final h = localHistoryMap.putIfAbsent(agent, () => []);
    final turn = h.isEmpty ? 1 : h.last.turn + 1;
    final ms = (at ?? DateTime(2026, 10, 2, 14, 30)).millisecondsSinceEpoch;
    h
      ..add(LocalItem(seq: ++_localSeq, turn: turn, role: 'owner', text: said, tsMs: ms))
      ..add(LocalItem(
          seq: ++_localSeq, turn: turn, role: 'agent', text: reply, tsMs: ms + 2000, outcome: outcome, detail: detail));
    final a = localAgentList.where((x) => x.name == agent).firstOrNull;
    if (a != null) {
      setLocalAgent(LocalAgentInfo(
          name: a.name, model: a.model, runtime: a.runtime, state: LocalAgentState.idle, turns: turn, createdMs: a.createdMs));
    }
  }

  Future<LocalModelsReply> localModels() async {
    _v7('local_models');
    return LocalModelsReply(
        hardware: localHardware, runtime: localRuntime, models: localModelList, agents: localAgentList);
  }

  Future<LocalModelInfo> modelInstall(String model, {String? fromFile}) async {
    _v7('model_install');
    installCalls.add((model, fromFile));
    final err = installError;
    if (err != null) {
      installError = null;
      throw err;
    }
    _model(model);
    return setLocalModel(model, (m) => _with(m, state: LocalModelState.downloading, doneBytes: 0));
  }

  Future<LocalModelInfo> modelRemove(String model) async {
    _v7('model_remove');
    removeCalls.add(model);
    _model(model);
    return setLocalModel(model, (m) => _with(m, state: LocalModelState.available, doneBytes: 0));
  }

  Future<LocalAgentInfo> localAgentAdd(String name, {required String model, required String password}) async {
    _v7('local_agent_add');
    passwords['local_agent_add'] = password;
    if (!proofChecked && password != this.password) {
      throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
    }
    if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(name)) {
      throw const XControlException(XErrorCode.badRequest, 'agent name: 1-64 of A-Z a-z 0-9 . _ -');
    }
    if (agentList.any((a) => a.name == name) || localAgentList.any((a) => a.name == name)) {
      throw XControlException(XErrorCode.badRequest, 'agent $name already exists');
    }
    final m = _model(model);
    localAgentAdds.add((name, model));
    final a = setLocalAgent(LocalAgentInfo(
      name: name,
      model: model,
      runtime: 'local',
      state: m.ready ? LocalAgentState.sleeping : LocalAgentState.noModel,
      createdMs: DateTime(2026, 10, 2, 14, 31).millisecondsSinceEpoch,
    ));
    agentList = [...agentList, AgentInfo(name: name, createdMs: a.createdMs, links: const [], localModel: model)];
    return a;
  }

  XDialog localSay(String agent, String text, {bool interrupt = false}) {
    final d = FakeDialog(LocalSayRequest(agent: agent, text: text, interrupt: interrupt));
    dialogs.add(d);
    localSays.add((agent, text, d));
    try {
      _v7('local_say');
      _agent(agent);
    } on XControlException catch (e) {
      d.fail(e);
    }
    return d;
  }

  Future<LocalHistoryReply> localHistory(String agent, {int? limit, int? before}) async {
    _v7('local_history');
    _agent(agent);
    final all = localHistoryMap[agent] ?? const [];
    final older = before == null ? all : all.where((i) => i.seq < before).toList();
    final n = limit ?? 100;
    final page = older.length > n ? older.sublist(older.length - n) : older;
    return LocalHistoryReply(agent: agent, items: page, more: older.length > n);
  }

  Future<LocalAgentInfo> localSession(String agent, String action) async {
    _v7('local_session');
    sessionCalls.add((agent, action));
    final a = _agent(agent);
    if (action == LocalSessionAction.reset) localHistoryMap.remove(agent);
    return a;
  }
}

/// A copy of [m] with another state.
LocalModelInfo _with(LocalModelInfo m, {required String state, int? doneBytes, int? speed, String? errorCode}) =>
    LocalModelInfo(
      id: m.id,
      name: m.name,
      maker: m.maker,
      license: m.license,
      licenseUrl: m.licenseUrl,
      languages: m.languages,
      params: m.params,
      quant: m.quant,
      sizeBytes: m.sizeBytes,
      memoryBytes: m.memoryBytes,
      context: m.context,
      source: m.source,
      fit: m.fit,
      estTokensPerS: m.estTokensPerS,
      state: state,
      doneBytes: doneBytes ?? m.doneBytes,
      speedBytesPerS: speed,
      errorCode: errorCode,
      agents: m.agents,
    );

/// The model in another state, as a `local_model` event would carry it.
LocalModelInfo modelInState(LocalModelInfo m, String state, {int? doneBytes, int? speed, String? errorCode}) =>
    _with(m, state: state, doneBytes: doneBytes, speed: speed, errorCode: errorCode);
