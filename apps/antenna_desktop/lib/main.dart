// SPDX-License-Identifier: AGPL-3.0-only
// Entry point: the Antenna window is a client of the `antennad` daemon (x-control socket). If the daemon does not
// answer and the app bundles `antennad`, the window starts it (macOS: LaunchAgent, Linux: child process, D-UI-10).

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'host/app_connect.dart';
import 'host/binaries.dart';
import 'host/cli_install.dart';
import 'host/daemon_host.dart';
import 'host/links.dart';
import 'host/notifier.dart';
import 'host/touch_id.dart';
import 'host/updater.dart';
import 'host/window_bridge.dart';
import 'protocol/x_control.dart';
import 'state/app_model.dart';
import 'state/appearance.dart';
import 'state/chat_prefs.dart';
import 'state/code_mode.dart';
import 'state/invite_link.dart';
import 'ui/app.dart';
import 'ui/code/code_offer.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  // An invite link in the arguments (Linux: .desktop `x-scheme-handler/antenna` → `antenna-desktop %u`). If a window is
  // already open, hand the link to it and exit instead of opening a second window.
  final linkArgs = args.where(looksLikeInviteLink).toList();
  if (Platform.isLinux) {
    final relay = LinkRelay.pathFor(env);
    if (relay != null) {
      if (linkArgs.isNotEmpty && await LinkRelay.forward(relay, linkArgs.first)) exit(0);
      unawaited(LinkRelay.serve(relay, IncomingLinks.instance.add));
    }
  }
  linkArgs.forEach(IncomingLinks.instance.add);
  // macOS delivers antenna:// links to the app (Info.plist CFBundleURLTypes → AppDelegate → channel).
  if (Platform.isMacOS) unawaited(IncomingLinks.instance.attachMacos());
  final fallback = defaultSocketPath(env);
  // Socket: --dart-define=ANTENNA_SOCKET=… (handy for `flutter run` with an ssh-forwarded socket; the old X_SOCKET is a
  // fallback), otherwise the environment, as for the `antenna` CLI.
  const defined = String.fromEnvironment('ANTENNA_SOCKET', defaultValue: String.fromEnvironment('X_SOCKET'));
  final socket = defined.isNotEmpty ? defined : fallback;
  final bins = locateCore(env: env, executable: Platform.resolvedExecutable);
  final store = AppearanceStore.forEnv(env);
  final look = store == null ? Appearance() : Appearance.load(store);
  final host = defaultHost(
    xdPath: bins.daemon,
    socketPath: socket,
    defaultSocket: fallback,
    env: env,
    logPath: defaultDaemonLog(env),
  );
  // Windows (D-135): the daemon's endpoint is a named pipe, reached through one `antenna.exe window-bridge` per daemon.
  final bridges = Platform.isWindows && bins.cli != null
      ? WindowBridges(cli: bins.cli!, env: env, defaultSocket: fallback)
      : null;
  final model = AppModel(
    connector: (path) => XControlClient(path, bridge: bridges?.forSocket(path)),
    socketPath: socket,
    host: host,
    binaries: bins,
    // The terminal command links to the CLI inside the app, not to one found in PATH.
    cliInstaller: bins.bundled && bins.cli != null && (env['HOME'] ?? '').isNotEmpty
        ? CliInstaller(cliPath: bins.cli!, home: env['HOME']!)
        : null,
    // Updates go through the CLI: it verifies the release signature, the window only shows the result.
    updater: bins.cli == null ? null : AntennaUpdater(cliPath: bins.cli!),
    defaultSocket: fallback,
    // Code mode: agent CLIs in terminals inside the window (DESIGN "Code mode").
    agentHost: AgentHost.system(env, cli: bins.cli),
    // Agents → AI apps: Connect edits an app's MCP file (after the owner saw it) or opens its install link.
    connectorFs: SystemConnectorFs(),
    appLauncher: SystemAppLauncher(),
    // Code mode agents come back after an automatic update (D-103): what they need is kept in the settings file.
    agentRuns: store == null ? null : look,
    // Touch ID for owner commands (D-102): the Secure Enclave keys on a Mac; nothing on Linux.
    touchId: ChannelTouchId.forPlatform(env),
    // A contact's agent chats: a stable order, pins, local picture overrides (D-UI-43); this computer only.
    chatPrefs: ChatPrefsStore.forEnv(env),
  );
  final navigator = GlobalKey<NavigatorState>();
  // On window close: no agent is left running (ask first, then stop them), then stop a child-process daemon and
  // leave a LaunchAgent daemon running.
  AppLifecycleListener(onExitRequested: () async {
    final running = model.liveRuns.length;
    if (running > 0) {
      final ctx = navigator.currentContext;
      if (ctx != null && !await confirmQuitWithAgents(ctx, running)) return AppExitResponse.cancel;
      await model.stopAllRuns();
    }
    await model.onWindowExit();
    return AppExitResponse.exit;
  });
  runApp(XApp(
    model: model,
    appearance: look,
    navigatorKey: navigator,
    // "An agent is waiting for your approval" while the window is not in focus (D-84).
    notifier: systemNotifierFor(env),
  ));
  unawaited(model.connect());
}
