// SPDX-License-Identifier: AGPL-3.0-only
// Where `antennad` and `antenna` live. Pure Dart (dart:io), no Flutter.
//
// Search order: environment variable → inside the app → PATH and the usual install locations (ProgramLocator).
// Inside the app: on macOS, `Antenna.app/Contents/Helpers/<name>` (placed there by packaging/macos/build-dmg.sh);
// on Linux, `<executable dir>/bin/<name>` (the `flutter build linux` bundle, packaging) or next to the executable; on
// Windows, `antennad.exe` and `antenna.exe` next to the window's executable, and only there (D-135): never a daemon
// found on PATH.

import 'dart:io';

import 'program_locator.dart';

/// The core binaries that were found.
final class CoreBinaries {
  const CoreBinaries({this.daemon, this.cli, this.bundled = false});

  /// `antennad`, the daemon.
  final String? daemon;

  /// `antenna`, the CLI (its path goes into agent configs and into the "command in the terminal" symlink).
  final String? cli;

  /// Taken from the app itself (not from the system).
  final bool bundled;
}

/// Environment variables that override binary paths (development, tests); the old names are fallbacks.
const daemonBinEnv = ['ANTENNAD_BIN', 'X_XD_BIN'];
const cliBinEnv = ['ANTENNA_CLI_BIN', 'X_CLI_BIN'];

/// Locate the binaries. [env] is the environment, [executable] the path of the window's executable
/// (`Platform.resolvedExecutable`).
CoreBinaries locateCore({
  required Map<String, String> env,
  required String executable,
  bool Function(String path)? exists,
  String? os,
}) {
  final isFile = exists ?? (String p) => File(p).existsSync();
  final system = os ?? Platform.operatingSystem;
  final windows = system == 'windows';
  final sep = windows ? r'\' : '/';
  final suffix = windows ? '.exe' : '';
  // Windows paths are split by hand, so the lookup reads the same when tested on another system.
  final exeDir = windows
      ? executable.substring(0, executable.lastIndexOf(sep).clamp(0, executable.length))
      : File(executable).parent.path;
  // macOS: the core lives only in Contents/Helpers. Contents/MacOS holds the `Antenna` window itself, and APFS is
  // usually case-insensitive, so `MacOS/antenna` would be "found" as the CLI. Windows: next to the window only.
  final bundleDirs = <String>[
    if (system == 'macos')
      '${File(exeDir).parent.path}/Helpers'
    else if (windows)
      exeDir
    else ...['$exeDir/bin', exeDir],
  ];
  // Outside the bundle (development, the install.sh archive): the same folders as every other program the window
  // looks for (program_locator.dart), without the login shell, which this start-up search does not wait for.
  final systemDirs = ProgramLocator(env: env, isExecutable: isFile, windows: windows).searchDirs;

  bool isWindow(String p) =>
      system == 'macos' || windows ? p.toLowerCase() == executable.toLowerCase() : p == executable;

  String? find(String name, List<String> envVars, {required bool bundleOnly}) {
    for (final v in envVars) {
      final explicit = env[v];
      if (explicit != null && explicit.isNotEmpty && isFile(explicit)) return explicit;
    }
    for (final d in bundleOnly ? bundleDirs : systemDirs) {
      final p = '$d$sep$name$suffix';
      if (isWindow(p)) continue;
      if (isFile(p)) return p;
    }
    return null;
  }

  final bd = find('antennad', daemonBinEnv, bundleOnly: true);
  final bc = find('antenna', cliBinEnv, bundleOnly: true);
  // Windows (D-135): the daemon and the bridge come from next to the window, or from the development variables.
  if (windows) return CoreBinaries(daemon: bd, cli: bc, bundled: bd != null);
  if (bd != null) {
    return CoreBinaries(daemon: bd, cli: bc ?? find('antenna', cliBinEnv, bundleOnly: false), bundled: true);
  }
  return CoreBinaries(
    daemon: find('antennad', daemonBinEnv, bundleOnly: false),
    cli: bc ?? find('antenna', cliBinEnv, bundleOnly: false),
  );
}

/// Where the daemon writes its log when the window starts it. Windows: `%LOCALAPPDATA%\AntennaLogs`, beside the data
/// folder and never inside it: the window must not make the data folder (WP-4), which the daemon makes for the user
/// alone.
String defaultDaemonLog(Map<String, String> env, {String? os}) {
  final system = os ?? Platform.operatingSystem;
  if (system == 'windows') {
    final local = env['LOCALAPPDATA'];
    return '${local != null && local.isNotEmpty ? local : '.'}\\AntennaLogs\\antennad.log';
  }
  final home = env['HOME'] ?? '.';
  if (system == 'macos') return '$home/Library/Logs/Antenna/antennad.log';
  final state = env['XDG_STATE_HOME'];
  return '${state != null && state.isNotEmpty ? state : '$home/.local/state'}/antenna/antennad.log';
}
