// SPDX-License-Identifier: AGPL-3.0-only
// The Check panel (D-96 phase 1, D-UI-26): fixed checks of this computer and node, each with a fix the owner runs with
// one click. No model is involved: every check reads what the window already has (the phase, daemon replies, the
// program locator, the apps' files) or one fact the daemon reports (a link endpoint's relay status, a process refused
// with `token_bound`), and every fix is an owner action of the window through the existing control protocol or a
// local action with consent (start the daemon, unlock, the shell profile line, an app's own Quit and open). Nothing
// here is given to agents. Checks are pure functions of their inputs; [DoctorMixin] gathers the inputs.
//
// Codes follow docs/LOCAL-ASSISTANT.md §4.1: `daemon_down`, `keys_locked`, `relay_unreachable`, `ai_cli_missing`,
// `ai_cli_not_on_path`, `app_restart_needed`, `token_bound_elsewhere`; plus `relay_disabled` and
// `screen_recording_missing` (macOS Screen Recording for this build, D-UI-41).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../host/app_connect.dart' show AppQuitResult;
import '../host/daemon_host.dart';
import '../host/screen_permission.dart';
import '../host/shell_path.dart';
import '../protocol/x_control.dart';
import 'agent_launch.dart' show AgentCli;
import 'agent_status.dart';
import 'ai_apps.dart';
import 'ai_apps_model.dart';
import 'app_model.dart' show Phase;
import 'code_mode.dart';
import 'code_shot.dart';
import 'lan.dart';

enum CheckState {
  /// Fine.
  ok,

  /// Something to fix.
  problem,

  /// Worth knowing, nothing broken.
  info,

  /// Could not check (and the panel says why).
  unknown,
}

/// One row of the Check panel.
sealed class Check {
  const Check(this.state);
  final CheckState state;

  /// The problem's code (`null` when fine or not checked).
  String? get code;
}

/// Antenna's background service (`daemon_down`).
final class DaemonCheck extends Check {
  const DaemonCheck(super.state, {this.daemon, this.protocol, required this.canStart, required this.socket, this.error});
  final String? daemon;
  final String? protocol;

  /// The window starts this daemon itself (its own LaunchAgent or child); otherwise the socket is someone else's.
  final bool canStart;
  final String socket;
  final DaemonStartException? error;

  @override
  String? get code => state == CheckState.problem ? 'daemon_down' : null;
}

/// The keys (`keys_locked`): locked, or unlocked without this window's session.
final class KeysCheck extends Check {
  const KeysCheck(super.state, this.phase);
  final Phase phase;

  bool get signIn => phase == Phase.loginRequired;

  @override
  String? get code => state == CheckState.problem ? 'keys_locked' : null;
}

/// One link whose endpoint cannot reach its relay.
@immutable
final class RelayLink {
  const RelayLink({required this.contact, required this.trust, required this.url, this.error});
  final String contact;
  final int trust;
  final String url;
  final String? error;

  /// Levels 1–2 connect only through the relay (SPEC §4): without it the link is down.
  bool get relayOnly => trust <= 2;
}

/// The relay (`relay_unreachable`, `relay_disabled`).
final class RelayCheck extends Check {
  const RelayCheck(super.state,
      {this.setting, this.down = const [], this.connected = 0, this.disabled = false, this.relayOnlyContacts = 0, this.reason});

  /// `n0`, `disabled` or the relay's URL (`status.relay`).
  final String? setting;

  /// Links whose endpoint is not connected to its relay.
  final List<RelayLink> down;

  /// Links whose endpoint is connected to its relay.
  final int connected;

  /// The node runs without a relay.
  final bool disabled;

  /// Contacts at levels 1–2 (relay only).
  final int relayOnlyContacts;

  /// Why it could not be checked.
  final UnknownReason? reason;

  @override
  String? get code => state != CheckState.problem
      ? null
      : disabled
          ? 'relay_disabled'
          : 'relay_unreachable';
}

/// Why a check could not run.
enum UnknownReason {
  /// The daemon does not answer.
  noDaemon,

  /// The keys are locked (or the window has no session).
  locked,

  /// The daemon is older than this check (it does not report the fact).
  olderDaemon,

  /// The login shell's PATH could not be read.
  noLoginShell,
}

/// An AI app's command-line program (`ai_cli_missing`, `ai_cli_not_on_path`).
final class CliCheck extends Check {
  const CliCheck(super.state,
      {required this.app, this.path, this.searched = const [], this.fix, this.missing = false, this.reason});
  final AiAppDef app;

  /// Where it was found.
  final String? path;

  /// Where it was looked for, in order (when missing).
  final List<String> searched;

  /// The profile line that puts its folder on PATH (`null`: on PATH already, or the folder is not plain text).
  final PathFix? fix;
  final bool missing;
  final UnknownReason? reason;

  /// The program's folder.
  String? get folder => path?.substring(0, path!.lastIndexOf('/'));

  @override
  String? get code => state == CheckState.problem
      ? (missing ? 'ai_cli_missing' : 'ai_cli_not_on_path')
      : state == CheckState.info && missing
          ? 'ai_cli_missing'
          : null;
}

/// A connected app that has not started Antenna since it was connected (`app_restart_needed`).
final class AppRestartCheck extends Check {
  const AppRestartCheck(super.state, {required this.app, required this.appPath, required this.agent});
  final AiAppDef app;

  /// The app bundle the window can quit and open.
  final String appPath;
  final String agent;

  @override
  String? get code => state == CheckState.problem ? 'app_restart_needed' : null;
}

/// A process refused because the agent's token is bound to another app.
@immutable
final class TokenRefusal {
  const TokenRefusal({
    required this.agent,
    required this.refusedComm,
    required this.refusedPid,
    required this.at,
    required this.refusedAlive,
    this.boundComm,
    this.boundPid,
    this.app,
  });
  final String agent;
  final String refusedComm;
  final int refusedPid;
  final DateTime at;
  final bool refusedAlive;

  /// The process that holds the token now.
  final String? boundComm;
  final int? boundPid;

  /// The AI app the agent was made for.
  final AiAppDef? app;

  /// The refused program can run in Code mode as an agent of its own.
  AgentCli? get cli => switch (refusedComm) {
        'claude' => AgentCli.claude,
        'codex' => AgentCli.codex,
        _ => null,
      };
}

/// Agent tokens held by one app while another tries them (`token_bound_elsewhere`, D-97).
final class TokenCheck extends Check {
  const TokenCheck(super.state, {this.refusals = const [], this.reason});
  final List<TokenRefusal> refusals;
  final UnknownReason? reason;

  @override
  String? get code => state == CheckState.problem ? 'token_bound_elsewhere' : null;
}

/// macOS Screen Recording for this build (`screen_recording_missing`): what the screenshot tool for agents needs.
final class ScreenRecordingCheck extends Check {
  const ScreenRecordingCheck(super.state);

  @override
  String? get code => state == CheckState.problem || state == CheckState.info ? 'screen_recording_missing' : null;
}

// The checks, as pure functions.

DaemonCheck checkDaemon(Phase phase,
    {required bool canStart, required String socket, HelloOk? hello, DaemonStartException? error}) {
  if (phase == Phase.unreachable) {
    return DaemonCheck(CheckState.problem, canStart: canStart, socket: socket, error: error);
  }
  if (phase == Phase.connecting) return DaemonCheck(CheckState.unknown, canStart: canStart, socket: socket);
  return DaemonCheck(CheckState.ok,
      daemon: hello?.daemon, protocol: hello?.proto ?? hello?.protocol, canStart: canStart, socket: socket);
}

KeysCheck checkKeys(Phase phase) => KeysCheck(
    switch (phase) {
      Phase.unlocked => CheckState.ok,
      Phase.locked || Phase.loginRequired => CheckState.problem,
      Phase.uninitialized => CheckState.info,
      Phase.connecting || Phase.unreachable => CheckState.unknown,
    },
    phase);

RelayCheck checkRelay(Phase phase, {StatusReply? status, required List<ContactInfo> contacts}) {
  if (phase == Phase.unreachable || phase == Phase.connecting) {
    return const RelayCheck(CheckState.unknown, reason: UnknownReason.noDaemon);
  }
  final setting = status?.relay;
  if (phase != Phase.unlocked) return RelayCheck(CheckState.unknown, setting: setting, reason: UnknownReason.locked);
  final relayOnly = contacts.where((c) => c.trust <= 2).length;
  if (setting == 'disabled') {
    return RelayCheck(relayOnly > 0 ? CheckState.problem : CheckState.info,
        setting: setting, disabled: true, relayOnlyContacts: relayOnly);
  }
  final reported = [for (final c in contacts) if (c.transport.relay != null) c];
  // PG-32: a link whose relay is down but which is connected anyway (over LAN mDNS or a direct address,
  // `c.transport.connected`) is not a finding — "LAN only" is a state the owner chose, not a fault.
  final down = [
    for (final c in reported)
      if (!c.transport.relay!.connected && !c.transport.connected)
        RelayLink(contact: c.label, trust: c.trust, url: c.transport.relay!.url, error: c.transport.relay!.error),
  ];
  if (down.isNotEmpty) {
    return RelayCheck(CheckState.problem,
        setting: setting, down: down, connected: reported.length - down.length, relayOnlyContacts: relayOnly);
  }
  if (reported.isEmpty && contacts.isNotEmpty) {
    return RelayCheck(CheckState.unknown, setting: setting, reason: UnknownReason.olderDaemon);
  }
  return RelayCheck(CheckState.ok, setting: setting, connected: reported.length, relayOnlyContacts: relayOnly);
}

/// [app]'s program: found on the login shell's PATH (ok), found elsewhere (the PATH line), or missing. [chosen]: the
/// owner uses the app (connected, or started in Code mode): a missing program is then a problem, else worth knowing.
CliCheck checkCli(
  AiAppDef app, {
  required String? Function(String name) locate,
  required List<String> searched,
  required List<String>? loginPath,
  required bool chosen,
  required String shell,
  required String home,
  required bool macos,
}) {
  String? path;
  for (final b in app.binaries) {
    path = locate(b);
    if (path != null) break;
  }
  if (path == null) {
    return CliCheck(chosen ? CheckState.problem : CheckState.info, app: app, searched: searched, missing: true);
  }
  if (loginPath == null) return CliCheck(CheckState.unknown, app: app, path: path, reason: UnknownReason.noLoginShell);
  final folder = path.substring(0, path.lastIndexOf('/'));
  if (loginPath.contains(folder) || loginPath.contains('$folder/')) return CliCheck(CheckState.ok, app: app, path: path);
  return CliCheck(CheckState.problem, app: app, path: path, fix: pathFixFor(folder, shell: shell, home: home, macos: macos));
}

/// Screen Recording as macOS reports it for this build; `null` where the system has no such permission (Linux), so
/// the panel shows no row. Missing is a problem once a screenshot met it, worth knowing before that (the owner may
/// never take one).
ScreenRecordingCheck? checkScreenRecording(ScreenPermission permission, {required bool blocked}) =>
    switch (permission) {
      ScreenPermission.notApplicable => null,
      ScreenPermission.granted => const ScreenRecordingCheck(CheckState.ok),
      ScreenPermission.missing => ScreenRecordingCheck(blocked ? CheckState.problem : CheckState.info),
      ScreenPermission.unknown => const ScreenRecordingCheck(CheckState.unknown),
    };

/// A refusal is shown while the refused process runs, or for 10 minutes after it.
const refusalShown = Duration(minutes: 10);

/// A process name as a process chose it (it can be anything): control, format and bidi characters become spaces,
/// at most 40 characters.
String processName(String comm) {
  final s = comm.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069]'), ' ').trim();
  return s.length <= 40 ? s : s.substring(0, 40);
}

TokenCheck checkTokens(Phase phase,
    {required List<AgentInfo> agents, required DateTime now, AiAppDef? Function(String agent)? appOf}) {
  if (phase == Phase.unreachable || phase == Phase.connecting) {
    return const TokenCheck(CheckState.unknown, reason: UnknownReason.noDaemon);
  }
  if (phase != Phase.unlocked) return const TokenCheck(CheckState.unknown, reason: UnknownReason.locked);
  final out = <TokenRefusal>[];
  for (final a in agents) {
    final pid = a.refusedPid, ms = a.refusedMs;
    if (pid == null || ms == null) continue;
    final at = DateTime.fromMillisecondsSinceEpoch(ms);
    final alive = a.refusedAlive ?? false;
    if (!alive && now.difference(at) > refusalShown) continue;
    final b = a.binding;
    out.add(TokenRefusal(
      agent: a.name,
      refusedComm: processName(a.refusedComm ?? ''),
      refusedPid: pid,
      at: at,
      refusedAlive: alive,
      boundComm: b?.alive ?? false ? processName(b!.comm) : null,
      boundPid: b?.alive ?? false ? b!.pid : null,
      app: appOf?.call(a.name),
    ));
  }
  // A daemon older than preview.6 reports no refusals at all; the panel says the check needs preview.6.
  return out.isNotEmpty ? TokenCheck(CheckState.problem, refusals: out) : const TokenCheck(CheckState.ok);
}

/// The panel's rows and the fixes' plumbing, in the window model.
mixin DoctorMixin on ChangeNotifier, CodeMixin, CodeShotMixin, AiAppsMixin, LanMixin {
  Phase get phase;
  DaemonHost? get host;
  DaemonStartException? get hostError;
  HelloOk? get hello;
  StatusReply? get status;
  List<ContactInfo> get contacts;
  Future<void> refreshContacts();

  /// The rows of the last check, in display order.
  List<Check> checks = const [];
  bool checking = false;
  DateTime? checkedAt;

  /// Problems in the last check.
  int get checkProblems => checks.where((c) => c.state == CheckState.problem).length;

  /// Run every check again, after reading fresh facts.
  Future<void> runChecks() async {
    if (checking) return;
    checking = true;
    safeNotify();
    try {
      if (phase == Phase.unlocked) await Future.wait([refreshContacts(), refreshAgents(), refreshLan()]);
      final host = agentHost;
      if (host != null) {
        await host.loadLoginShell();
        scanAiApps(notify: false);
      }
      final screen =
          host == null ? null : checkScreenRecording(await checkScreenPermission(), blocked: screenPermissionBlocked);
      checks = [
        checkDaemon(phase, canStart: this.host != null, socket: socketPath, hello: hello, error: hostError),
        checkKeys(phase),
        checkRelay(phase, status: status, contacts: contacts),
        ..._cliChecks(),
        ...await _restartChecks(),
        ?screen,
        checkTokens(phase, agents: phase == Phase.unlocked ? agents : const [], now: now(), appOf: appOfAgent),
      ];
      checkedAt = now();
    } finally {
      checking = false;
      safeNotify();
    }
  }

  List<CliCheck> _cliChecks() {
    final host = agentHost;
    if (host == null) return const [];
    final usedClis = {for (final r in runs) r.spec.cli};
    final rows = [for (final a in aiApps) if (a.installUrl != null && a.availableOn(macos: host.macos)) aiAppRow(a)];
    return [
      for (final row in rows)
        // Claude Code and Codex always (Code mode starts them); other programs once the owner connected them.
        if (row.app.terminal != null || row.connected)
          checkCli(
            row.app,
            locate: host.programs.locate,
            searched: host.programs.searchDirs,
            loginPath: host.programs.loginShellPath,
            chosen: row.connected || usedClis.contains(row.app.terminal),
            shell: host.env['SHELL'] ?? '/bin/sh',
            home: host.home,
            macos: host.macos,
          ),
    ];
  }

  /// Apps that read their MCP settings only at start, connected here, running, whose agent no process holds: they
  /// started before Connect wrote their file (macOS app bundles; elsewhere the window cannot tell).
  Future<List<AppRestartCheck>> _restartChecks() async {
    if (phase != Phase.unlocked) return const [];
    final out = <AppRestartCheck>[];
    for (final row in aiAppRows) {
      if (!row.connected || row.configAgent == null || row.configAgent!.isEmpty) continue;
      final r = restartOf(row.app);
      final state = row.status?.state;
      if (r.kind != AppRestartKind.bundle || (state != AgentLinkState.waiting && state != AgentLinkState.disconnected)) {
        continue;
      }
      if (await aiAppRunning(r.appPath!) ?? false) {
        out.add(AppRestartCheck(CheckState.problem, app: row.app, appPath: r.appPath!, agent: row.configAgent!));
      }
    }
    return out;
  }

  /// "Add `folder` to PATH": append the line (after a backup), then read the login shell again and check.
  Future<(PathFixResult, String?)> applyPathFixAndCheck(PathFix fix, {ProfileFs fs = const SystemProfileFs()}) async {
    final r = applyPathFix(fix, fs: fs, now: now());
    await agentHost?.programs.reloadLoginShell();
    unawaited(runChecks());
    return r;
  }

  /// "Restart `app`": its own Quit, then open it again; the owner confirmed.
  Future<bool> restartApp(AppRestartCheck c) async {
    final q = await quitAiApp(c.appPath);
    if (q != AppQuitResult.quit) return false;
    final ok = await openAiApp(c.appPath);
    unawaited(runChecks());
    return ok;
  }
}
