// SPDX-License-Identifier: AGPL-3.0-only
// The window bridge's process on Windows (D-135, docs/CONTROL.md §34): `antenna.exe window-bridge`, the CLI from
// CoreBinaries.cli (next to the window's executable, or ANTENNA_CLI_BIN in development; never PATH). The bridge finds
// the daemon's pipe itself, exactly as the CLI does, so the window never computes a pipe name. Pure Dart (dart:io), no
// Flutter.

import '../protocol/x_control.dart';

/// The bridge's arguments before `window-bridge`: only what the window was given. `--socket` for an explicit endpoint
/// ([socket]: a build-time define, or another daemon chosen in the window; else `ANTENNA_SOCKET`), and `--data-dir`
/// when `ANTENNA_DATA_DIR` is set. Everything else (the legacy variables, the default data folder and its pipe name) is
/// the CLI's own resolution in the environment it inherits.
List<String> windowBridgeArgs(Map<String, String> env, {String? socket}) {
  final s = socket ?? env['ANTENNA_SOCKET'];
  final dataDir = env['ANTENNA_DATA_DIR'];
  return [
    if (dataDir != null && dataDir.isNotEmpty) ...['--data-dir', dataDir],
    if (s != null && s.isNotEmpty) ...['--socket', s],
  ];
}

/// One bridge per daemon the window talks to: its default daemon, or another socket the owner chose in the window.
final class WindowBridges {
  WindowBridges({
    required this.cli,
    required this.env,
    required this.defaultSocket,
    BridgeMux Function(String cli, List<String> arguments)? make,
  }) : _make = make ?? ((cli, arguments) => BridgeMux.process(cli, arguments: arguments));

  /// `antenna.exe` (CoreBinaries.cli).
  final String cli;
  final Map<String, String> env;

  /// The socket path the window uses when nothing was chosen; it is not passed to the bridge, which resolves the
  /// default itself.
  final String defaultSocket;
  final BridgeMux Function(String cli, List<String> arguments) _make;
  final _muxes = <String, BridgeMux>{};

  /// The bridge for [socketPath].
  BridgeMux forSocket(String socketPath) => _muxes.putIfAbsent(
        socketPath,
        () => _make(cli, windowBridgeArgs(env, socket: socketPath == defaultSocket ? null : socketPath)),
      );
}
