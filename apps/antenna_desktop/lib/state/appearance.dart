// SPDX-License-Identifier: AGPL-3.0-only
// Window appearance: theme (light by default, dark following the system or via the switch), language (English by
// default, Russian if the system language is Russian, or an explicit choice in "Settings") and the interface mode
// (Chat by default; Code puts the agents' terminals in the window).
// The choice is kept in a small window settings file, `{"theme": …, "lang": …, "ui": …, "code_offered": …,
// "self_notice_shown": …, "agent_runs": {agent: {cli, dir, cmd?, session?, token_file?, restore?, running?, started_ms?,
// restored_ms?}}, "code_wake_off": [agent…], "agent_map": {"clusters": {id: [x, y]}, "order": {id: [node…]}, "view":
// [scale, dx, dy], "recent": bool}}`; the window stores no passwords, tokens, history or links (`token_file` is the
// path of the daemon's token file, D-86: what a Code mode agent restored after an update reads, D-103). `agent_map` is
// how the owner arranged the agent map in this window (agent_map_prefs.dart, D-UI-47).

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import 'agent_map_prefs.dart';

enum ThemeChoice { system, light, dark }

/// Window language: "same as system" or explicit.
enum LangChoice { system, en, ru }

/// Interface mode: Chat (conversations only) or Code (plus the agents' terminals next to the conversation).
enum InterfaceMode { chat, code }

/// The role new agents start with: the data label the window proposes (Q-15: the owner picks it; there is no silent
/// default, so until the owner chooses a preset, nothing is preselected).
enum RolePreset {
  /// Sees the owner's projects and memory: data label 5.
  assistant(5),

  /// Messages only, no local data: data label 0.
  frontDesk(0);

  const RolePreset(this.level);
  final int level;
}

/// Window languages (in `supportedLocales` order); English is the default.
const windowLanguages = ['en', 'ru'];

/// Window language from the choice and the system languages ([system] is `PlatformDispatcher.locales`, in order of
/// preference): "same as system" picks the first system language the window knows; if none, English.
Locale resolveLanguage(LangChoice choice, List<Locale> system) => switch (choice) {
      LangChoice.en => const Locale('en'),
      LangChoice.ru => const Locale('ru'),
      LangChoice.system => Locale(
          system.map((l) => l.languageCode).firstWhere(windowLanguages.contains, orElse: () => windowLanguages.first)),
    };

/// The `agent_runs` entries of the settings file, as Code mode reads and writes them: how each agent was last started
/// (`cli`, `dir`, `cmd`) and what a restore after an update needs (code_restore.dart): `session`, `token_file` (the
/// daemon's file's path; never a token), `restore` (`false` when off; on by default), `running`, `started_ms`,
/// `restored_ms`.
abstract interface class AgentRunStore {
  Iterable<String> get agentRunNames;

  /// The entry for [agent] (`null`: none).
  Map<String, Object?>? agentRunRecord(String agent);

  /// Set these fields of [agent]'s entry (a `null` value removes the field) and save.
  void patchAgentRun(String agent, Map<String, Object?> fields);
}

/// The fields of an `agent_runs` entry that belong to the restore after an update, not to the start dialog.
const restoreFields = {'session', 'token_file', 'restore', 'running', 'started_ms', 'restored_ms'};

/// Everything the settings file holds.
typedef WindowPrefs = ({
  ThemeChoice theme,
  LangChoice lang,
  InterfaceMode ui,
  bool codeOffered,
  bool selfNoticeShown,
  RolePreset? rolePreset,
  Map<String, Object?> agentRuns,
  Set<String> codeWakeOff,
  AgentMapPrefs agentMap,
});

class Appearance extends ChangeNotifier implements AgentRunStore {
  Appearance({
    ThemeChoice initial = ThemeChoice.system,
    this._lang = LangChoice.system,
    this._ui = InterfaceMode.chat,
    this._codeOffered = false,
    this._selfNoticeShown = false,
    this._rolePreset,
    Map<String, Object?>? agentRuns,
    Set<String>? codeWakeOff,
    this._agentMap = const AgentMapPrefs(),
    this.store,
  })  : _choice = initial,
        _agentRuns = {...?agentRuns},
        _codeWakeOff = {...?codeWakeOff};

  /// Load the choice from the file (if the file is missing or corrupt, the defaults).
  factory Appearance.load(AppearanceStore store) {
    final p = store.load();
    return Appearance(
      initial: p.theme,
      lang: p.lang,
      ui: p.ui,
      codeOffered: p.codeOffered,
      selfNoticeShown: p.selfNoticeShown,
      rolePreset: p.rolePreset,
      agentRuns: p.agentRuns,
      codeWakeOff: p.codeWakeOff,
      agentMap: p.agentMap,
      store: store,
    );
  }

  final AppearanceStore? store;
  ThemeChoice _choice;
  LangChoice _lang;
  InterfaceMode _ui;
  bool _codeOffered;
  bool _selfNoticeShown;
  RolePreset? _rolePreset;
  final Map<String, Object?> _agentRuns;
  final Set<String> _codeWakeOff;
  AgentMapPrefs _agentMap;

  void _save() => store?.save((
        theme: _choice,
        lang: _lang,
        ui: _ui,
        codeOffered: _codeOffered,
        selfNoticeShown: _selfNoticeShown,
        rolePreset: _rolePreset,
        agentRuns: _agentRuns,
        codeWakeOff: _codeWakeOff,
        agentMap: _agentMap,
      ));

  /// How the owner arranged the agent map in this window (D-UI-47).
  AgentMapPrefs get agentMap => _agentMap;

  /// Saved without notifying: the map keeps its own state while it shows, and the rest of the window does not draw
  /// any of it.
  set agentMap(AgentMapPrefs v) {
    _agentMap = v;
    _save();
  }

  /// Theme choice.
  ThemeChoice get choice => _choice;

  set choice(ThemeChoice v) {
    if (v == _choice) return;
    _choice = v;
    _save();
    notifyListeners();
  }

  LangChoice get lang => _lang;

  set lang(LangChoice v) {
    if (v == _lang) return;
    _lang = v;
    _save();
    notifyListeners();
  }

  /// Chat or Code; Chat for new users.
  InterfaceMode get ui => _ui;

  set ui(InterfaceMode v) {
    if (v == _ui) return;
    _ui = v;
    // Choosing a mode answers the one-time offer too.
    _codeOffered = true;
    _save();
    notifyListeners();
  }

  /// Code mode was offered once (the owner has agents). Without a settings file there is nothing to remember the
  /// answer in, so the offer is not shown at all ([canOfferCode]).
  bool get codeOffered => _codeOffered;

  bool get canOfferCode => store != null && !_codeOffered && _ui == InterfaceMode.chat;

  void dismissCodeOffer() {
    if (_codeOffered) return;
    _codeOffered = true;
    _save();
    notifyListeners();
  }

  /// The one-time notice about level 5 (it now also sends secrets without asking, maintainer decision 2026-10-05) is
  /// still to be shown, or to be marked as not needed. Without a settings file there is nowhere to remember it, so it
  /// is not shown at all, like the Code mode offer.
  bool get selfNoticeDue => store != null && !_selfNoticeShown;

  void markSelfNoticeShown() {
    if (_selfNoticeShown) return;
    _selfNoticeShown = true;
    _save();
  }

  /// The role new agents start with (`null`: the owner has not chosen one).
  RolePreset? get rolePreset => _rolePreset;

  set rolePreset(RolePreset? v) {
    if (v == _rolePreset) return;
    _rolePreset = v;
    _save();
    notifyListeners();
  }

  /// The last way each agent was started (CLI, folder, own command), so the next start is one click. Not secret.
  Object? agentRun(String agent) => _agentRuns[agent];

  /// The start dialog's choice for [agent]; what the restore keeps ([restoreFields]) stays.
  void rememberAgentRun(String agent, Map<String, Object?> spec) {
    final old = _agentRuns[agent];
    _agentRuns[agent] = {
      ...spec,
      if (old is Map)
        for (final k in restoreFields)
          if (old[k] != null) k: old[k],
    };
    _save();
  }

  @override
  Iterable<String> get agentRunNames => [..._agentRuns.keys];

  @override
  Map<String, Object?>? agentRunRecord(String agent) => switch (_agentRuns[agent]) {
        final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': e.value},
        _ => null,
      };

  @override
  void patchAgentRun(String agent, Map<String, Object?> fields) {
    final next = agentRunRecord(agent) ?? <String, Object?>{};
    for (final e in fields.entries) {
      if (e.value == null) {
        next.remove(e.key);
      } else {
        next[e.key] = e.value;
      }
    }
    _agentRuns[agent] = next;
    _save();
  }

  /// Agents in Code mode the window does not wake ("Wake on new messages" off; on by default, D-UI-23).
  Set<String> get codeWakeOff => {..._codeWakeOff};

  void setCodeWakeOff(Set<String> off) {
    if (setEquals(off, _codeWakeOff)) return;
    _codeWakeOff
      ..clear()
      ..addAll(off);
    _save();
  }
}

/// Window settings file: on macOS ~/Library/Application Support/Antenna/window.json,
/// on Linux $XDG_CONFIG_HOME/antenna/window.json (default ~/.config/antenna/window.json).
class AppearanceStore {
  AppearanceStore(this.path);
  final String path;

  static AppearanceStore? forEnv(Map<String, String> env, {bool? macos}) {
    final home = env['HOME'] ?? '';
    if (home.isEmpty) return null;
    if (macos ?? Platform.isMacOS) return AppearanceStore('$home/Library/Application Support/Antenna/window.json');
    final xdg = env['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.startsWith('/')) ? xdg : '$home/.config';
    return AppearanceStore('$base/antenna/window.json');
  }

  /// The choice from the file. A missing or corrupt file or an unknown value means the default (per field: an old
  /// file with only `theme` is still read, the language becomes "same as system" and the mode Chat).
  WindowPrefs load() {
    Object? j;
    try {
      j = json.decode(File(path).readAsStringSync());
    } on Object {
      j = null;
    }
    T pick<T extends Enum>(List<T> values, String key, T fallback) {
      final v = j is Map ? j[key] : null;
      return values.firstWhere((c) => c.name == v, orElse: () => fallback);
    }

    final runs = j is Map ? j['agent_runs'] : null;
    final wakeOff = j is Map ? j['code_wake_off'] : null;
    return (
      theme: pick(ThemeChoice.values, 'theme', ThemeChoice.system),
      lang: pick(LangChoice.values, 'lang', LangChoice.system),
      ui: pick(InterfaceMode.values, 'ui', InterfaceMode.chat),
      codeOffered: j is Map && j['code_offered'] == true,
      selfNoticeShown: j is Map && j['self_notice_shown'] == true,
      rolePreset: RolePreset.values.where((r) => j is Map && r.name == j['role_preset']).firstOrNull,
      agentRuns: runs is Map ? {for (final e in runs.entries) '${e.key}': e.value} : <String, Object?>{},
      codeWakeOff: wakeOff is List ? {for (final n in wakeOff) if (n is String) n} : <String>{},
      agentMap: AgentMapPrefs.fromJson(j is Map ? j['agent_map'] : null),
    );
  }

  void save(WindowPrefs p) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(json.encode({
        'theme': p.theme.name,
        'lang': p.lang.name,
        if (p.ui != InterfaceMode.chat) 'ui': p.ui.name,
        if (p.codeOffered) 'code_offered': true,
        if (p.selfNoticeShown) 'self_notice_shown': true,
        if (p.rolePreset case final r?) 'role_preset': r.name,
        if (p.agentRuns.isNotEmpty) 'agent_runs': p.agentRuns,
        if (p.codeWakeOff.isNotEmpty) 'code_wake_off': (p.codeWakeOff.toList()..sort()),
        if (!p.agentMap.isEmpty) 'agent_map': p.agentMap.toJson(),
      }));
      tmp.renameSync(path);
    } on Object catch (e) {
      debugPrint('window.json: $e');
    }
  }
}
