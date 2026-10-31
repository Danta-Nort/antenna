// SPDX-License-Identifier: AGPL-3.0-only
// Agents → AI apps in the window model: which apps are here, which are connected and as which agent, and the owner
// flows that connect and disconnect them (docs/CONNECT-APPS.md).
//
// Connect is the existing owner flow plus one file: the daemon issues the app's agent a token with the owner
// password (`agent_add` for a new agent, `agent_token` for an existing one) and writes it to the agent's token file;
// the window then writes the app's MCP entry, which names only that file. Disconnect removes the entry (after a
// backup) and the agent (`agent_remove`, which also deletes the token file).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../host/app_connect.dart';
import '../host/binaries.dart';
import '../protocol/x_control.dart';
import 'agent_status.dart';
import 'ai_apps.dart';
import 'code_mode.dart';
import 'mcp_config.dart';
import 'owner_auth.dart';

/// One row of Agents → AI apps.
final class AiAppRow {
  const AiAppRow(this.app, {this.foundAt, this.configAgent, this.agent});

  final AiAppDef app;

  /// Where the app was found on this computer (`null`: not found).
  final String? foundAt;

  /// The agent the app's configuration file names: its name, `''` for an entry that holds the token itself (set up
  /// by hand before token files), `null` when Antenna is not in the file (or the app has no file).
  final String? configAgent;

  /// The daemon's agent for this app (the one the file names, or the app's own agent name).
  final AgentInfo? agent;

  bool get found => foundAt != null;

  /// Antenna is in the app's file (apps the window writes or links), or the app's agent exists (apps set up through
  /// the guide, whose settings the window cannot read).
  bool get connected {
    final inFile = configAgent != null && configAgent!.isNotEmpty;
    return app.route == ConnectRoute.guide ? inFile || agent != null : inFile;
  }

  /// What the window shows: `null` when the app is not connected at all.
  AgentStatus? get status {
    if (agent != null) return AgentStatus.of(agent);
    if (configAgent != null && configAgent!.isNotEmpty) return const AgentStatus(AgentLinkState.revoked);
    return null;
  }

  /// An entry written by hand with the token in it (preview.3 snippets): reconnecting moves it to a token file.
  bool get legacyEntry => configAgent == '';
}

/// How an app loads the MCP entry Connect wrote ([AiAppsMixin.restartOf]).
final class AppRestart {
  const AppRestart.live()
      : kind = AppRestartKind.live,
        appPath = null;
  const AppRestart.bundle(String this.appPath) : kind = AppRestartKind.bundle;
  const AppRestart.cli()
      : kind = AppRestartKind.cli,
        appPath = null;
  const AppRestart.byHand()
      : kind = AppRestartKind.byHand,
        appPath = null;

  final AppRestartKind kind;

  /// The app bundle the window can quit and open ([AppRestartKind.bundle]).
  final String? appPath;
}

enum AppRestartKind {
  /// The app picks up the change by itself (VS Code, LM Studio) or its own install dialog added it.
  live,

  /// A macOS app that reads its settings only at start, found here: the window offers to restart or open it.
  bundle,

  /// A CLI (Codex, Gemini CLI, Grok Build): a new session reads the settings.
  cli,

  /// An app the window cannot restart (not found as an app bundle, or not macOS): the owner restarts it.
  byHand,
}

/// The result of issuing the app's agent its token.
final class AppAgentToken {
  const AppAgentToken({required this.agent, required this.token, this.tokenFile});
  final String agent;

  /// Kept only while the Connect dialog is open: shown only when the daemon could not write a token file (an older
  /// daemon), with a warning next to it.
  final String token;
  final String? tokenFile;
}

mixin AiAppsMixin on ChangeNotifier {
  XDaemon get daemon;

  /// The daemon speaks x-control/6 (`agent_add` takes `everyone`).
  bool get addressing;
  void safeNotify();
  DateTime now();
  AgentHost? get agentHost;
  CoreBinaries? get binaries;
  String get socketPath;
  bool get socketNeedsEnv;
  List<AgentInfo> get agents;
  Future<void> refreshAgents();

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);
  bool get live;

  /// The files Connect edits and the system's "open" (`null`: no Connect in this window, e.g. a test without them).
  ConnectorFs? get connectorFs;
  AppLauncher? get appLauncher;

  /// What was last found on this computer (Agents → AI apps), refreshed by [scanAiApps].
  final Map<AiApp, (String?, String?)> _scan = {};

  bool get aiAppsAvailable => agentHost != null;

  String get _home => agentHost?.home ?? '/';
  bool get _macos => agentHost?.macos ?? false;

  /// Windows: apps' files are found from its environment, never under a home folder (WP-17). The agent host says
  /// which system this is, as it does for macOS, so tests do not follow the machine they run on.
  WindowsPlace? get _windows {
    final host = agentHost;
    return host != null && host.windows ? windowsPlace(host.env) : null;
  }

  String? _read(String path) => connectorFs?.read(path);

  /// Look for the apps and read their configuration files again (cheap: a few small files). The first scan of a
  /// window session also reads the login shell's PATH in the background and scans again when it adds folders (a CLI
  /// installed with nvm or a custom npm prefix). [notify] `false`: called while a widget builds (the caller reads the
  /// rows right after).
  void scanAiApps({bool notify = true}) {
    final host = agentHost;
    if (host == null) return;
    for (final a in aiApps) {
      _scan[a.id] = (host.detect(a), configuredAgent(a, home: _home, macos: _macos, read: _read, windows: _windows));
    }
    if (notify) safeNotify();
    if (!host.programs.loginShellLoaded) {
      unawaited(host.loadLoginShell().then((more) {
        if (more) scanAiApps();
      }));
    }
  }

  AiAppRow aiAppRow(AiAppDef app) {
    final (found, configAgent) = _scan[app.id] ?? (null, null);
    final name = (configAgent != null && configAgent.isNotEmpty) ? configAgent : app.agent;
    return AiAppRow(app,
        foundAt: found, configAgent: configAgent, agent: agents.where((a) => a.name == name).firstOrNull);
  }

  /// The rows in display order: apps found here first (catalog order), then the others.
  List<AiAppRow> get aiAppRows {
    final rows = [for (final a in aiApps) if (a.availableOn(macos: _macos)) aiAppRow(a)];
    return [...rows.where((r) => r.found || r.connected), ...rows.where((r) => !r.found && !r.connected)];
  }

  /// The AI app an agent was created for (by its configuration or by its name), for its mark and wording.
  AiAppDef? appOfAgent(String agent) {
    for (final a in aiApps) {
      final (_, configAgent) = _scan[a.id] ?? (null, null);
      if (configAgent == agent || a.agent == agent) return a;
    }
    return null;
  }

  /// An AI app's configuration file on this computer names [agent] (Connect wrote it here): the agent runs on this
  /// computer whenever the app does.
  bool appConfiguredHere(String agent) => agent.isNotEmpty && _scan.values.any((s) => s.$2 == agent);

  /// The MCP server entry for [tokenFile].
  McpServer appServer(String tokenFile) =>
      McpServer.antenna(cli: binaries?.cli ?? 'antenna', tokenFile: tokenFile, socket: socketNeedsEnv ? socketPath : null);

  /// Step 1 of Connect: the app's agent and its token file. [create] makes a new agent (`agent_add`); otherwise the
  /// existing agent gets a new token (`agent_token`). [tasksFrom] (when set) changes whose messages the agent treats
  /// as tasks, with the same password. An older daemon without token files still gives the token, which the guide
  /// then shows with a warning.
  ///
  /// With one touch ([TouchAuth]) each owner command is its own touch (one touch is one command, D-102): the token,
  /// then, only when [setTasks], whose tasks it takes, with [tasksReason] on the second prompt.
  Future<(AppAgentToken?, Object?)> issueAppAgent(
    String agent, {
    required OwnerAuth auth,
    NewAgent? create,
    List<String>? tasksFrom,
    bool setTasks = false,
    String? tasksReason,
  }) async {
    try {
      AgentAddedReply r;
      Future<AgentAddedReply> issue(XDaemon d, String password, bool file) => create != null
          ? d.agentAdd(agent,
              localLevel: create.localLevel,
              password: password,
              links: create.links,
              tokenFile: file,
              everyone: addressing ? create.everyone : null)
          : d.agentToken(agent, password, tokenFile: file);
      try {
        r = await ownerOp(auth, (d, pw) => issue(d, pw, true));
      } on XControlException catch (e) {
        // A daemon from before token files rejects the unknown field (strict parsing): issue without it. Such a
        // daemon takes no proof either, so this happens only with the password.
        if (e.code != XErrorCode.badRequest || !e.message.contains('token_file') || auth is! PasswordAuth) rethrow;
        r = await issue(daemon, auth.password, false);
      }
      if (setTasks) {
        final second = switch (auth) {
          TouchAuth() => TouchAuth(tasksReason ?? auth.reason),
          PasswordAuth() => auth,
        };
        await ownerOp(second, (d, pw) => d.agentTasks(agent, pw, contacts: tasksFrom));
      }
      await refreshAgents();
      return (AppAgentToken(agent: r.name, token: r.token, tokenFile: r.tokenFile), null);
    } on XClientException catch (e) {
      return (null, e);
    }
  }

  /// Step 2 of Connect: what will be written (or opened) for [app] with [tokenFile].
  ConnectPlan planConnect(AiAppDef app, String tokenFile, {bool guide = false}) => guide
      ? GuidePlan(app)
      : connectPlan(app, appServer(tokenFile),
          home: _home, macos: _macos, found: agentHost?.detect(app) != null, read: _read, windows: _windows);

  /// Step 3 of Connect: back up the file and write it. Returns the backup's path (`null`: there was no file).
  Future<String?> applyConnect(WriteConfigPlan plan) async {
    final fs = connectorFs;
    if (fs == null) throw StateError('no file access for Connect');
    // The file may have changed since the owner saw the plan: never overwrite what they did not see.
    if (fs.read(plan.path) != plan.before) throw const ConfigChanged();
    String? backup;
    if (plan.before != null) backup = fs.backup(plan.path, now());
    if (plan.changes) fs.write(plan.path, plan.after);
    scanAiApps();
    return backup;
  }

  Future<bool> openAppLink(OpenLinkPlan plan) async => await appLauncher?.openUrl(plan.url) ?? false;

  /// Open a vendor's page (an install guide) in the browser; `false` when the system did not take it.
  Future<bool> openExternal(String url) async => await appLauncher?.openUrl(url) ?? false;

  /// How [app] picks up the entry Connect wrote: at once, or only when it starts.
  AppRestart restartOf(AiAppDef app) {
    if (!(app.config?.restart ?? false)) return const AppRestart.live();
    final found = aiAppRow(app).foundAt;
    // A macOS app bundle found here can be quit and opened again from the window (on the owner's click).
    if (_macos && found != null && found.endsWith('.app')) return AppRestart.bundle(found);
    return app.macApps.isEmpty ? const AppRestart.cli() : const AppRestart.byHand();
  }

  /// Whether the app bundle at [appPath] runs now (`null`: the window cannot tell).
  Future<bool?> aiAppRunning(String appPath) async => appLauncher?.appRunning(appPath);

  /// Quit the app bundle at [appPath] (its own Quit) and wait for it to exit. Only on the owner's click.
  Future<AppQuitResult> quitAiApp(String appPath) async =>
      await appLauncher?.quitApp(appPath) ?? AppQuitResult.failed;

  Future<bool> openAiApp(String appPath) async => await appLauncher?.openApp(appPath) ?? false;

  /// Disconnect: what will change in the app's file (`null`: nothing to remove there).
  WriteConfigPlan? planDisconnect(AiAppDef app) =>
      disconnectPlan(app, home: _home, macos: _macos, read: _read, windows: _windows);

  /// Disconnect: remove Antenna's entry (backup first) and the agent (its token stops working, the daemon deletes
  /// the token file). Returns the error or `null`.
  Future<Object?> disconnectApp(AiAppDef app, {required OwnerAuth auth, String? agent}) async {
    final plan = planDisconnect(app);
    final row = aiAppRow(app);
    final name = agent ?? row.agent?.name;
    try {
      if (name != null && agents.any((a) => a.name == name)) {
        await ownerOp(auth, (d, pw) => d.agentRemove(name, pw));
      }
    } on XClientException catch (e) {
      return e;
    }
    if (plan != null) {
      try {
        await applyConnect(plan);
      } on Object catch (e) {
        await refreshAgents();
        return e;
      }
    }
    await refreshAgents();
    scanAiApps();
    return null;
  }

  /// "Revoke and create a new token" (the token was shown somewhere it should not have been).
  Future<(AppAgentToken?, Object?)> rotateAgentToken(String agent, OwnerAuth auth) =>
      issueAppAgent(agent, auth: auth);

  /// Whose messages [agent] treats as tasks (owner password). [contacts] `null`: the default (trust level 5).
  Future<Object?> setAgentTasks(String agent, OwnerAuth auth, {List<String>? contacts}) async {
    try {
      await ownerOp(auth, (d, pw) => d.agentTasks(agent, pw, contacts: contacts));
      await refreshAgents();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  // Live status: while an Agents view is on screen, `agent_list` is read every few seconds (the daemon's `agent`
  // event covers binding at once; a process that exits is seen here).
  Timer? _agentPoll;
  int _agentPollUsers = 0;

  void watchAgents() {
    _agentPollUsers++;
    // Background work only in a live window (tests and goldens refresh by hand).
    if (live) _agentPoll ??= Timer.periodic(const Duration(seconds: 4), (_) => unawaited(refreshAgents()));
  }

  void unwatchAgents() {
    if (--_agentPollUsers > 0) return;
    _agentPollUsers = 0;
    _agentPoll?.cancel();
    _agentPoll = null;
  }

  void disposeAiApps() {
    _agentPoll?.cancel();
    _agentPoll = null;
  }
}

/// The app's file changed between the review and the write: the owner must see the new content first.
final class ConfigChanged implements Exception {
  const ConfigChanged();
}
