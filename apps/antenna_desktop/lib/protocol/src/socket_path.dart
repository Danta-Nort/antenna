// SPDX-License-Identifier: AGPL-3.0-only
// Where to look for the control socket, in the same order as the `antenna` CLI and the `antennad` daemon
// (docs/CONTROL.md §1, crates/antenna-proto/src/local.rs): `ANTENNA_SOCKET` → `ANTENNA_DATA_DIR/antennad.sock` →
// `$XDG_DATA_HOME/antenna/antennad.sock` → `~/.local/share/antenna/antennad.sock`; on Windows the default is
// `%LOCALAPPDATA%\Antenna\antennad.sock` (WP-3). The pre-release `x` variables (`X_SOCKET`, `X_DATA_DIR`) are fallbacks
// when the new ones are not set.

import 'dart:io';

/// File name of the daemon socket in the data directory.
const socketFileName = 'antennad.sock';

/// Name of the data directory under `$XDG_DATA_HOME` / `~/.local/share`.
const dataDirName = 'antenna';

/// Name of the data directory under `%LOCALAPPDATA%` (Windows).
const windowsDataDirName = 'Antenna';

/// Value of the variable [name], otherwise of the legacy [legacy]; an empty value counts as unset.
String? envWithFallback(Map<String, String> env, String name, String legacy) {
  final v = env[name];
  if (v != null && v.isNotEmpty) return v;
  final old = env[legacy];
  return old != null && old.isNotEmpty ? old : null;
}

/// Default socket path. [env] is the process environment (`Platform.environment`), [os] the system's name
/// (`Platform.operatingSystem` when not given).
String defaultSocketPath(Map<String, String> env, {String? os}) {
  final explicit = envWithFallback(env, 'ANTENNA_SOCKET', 'X_SOCKET');
  if (explicit != null) return explicit;
  final windows = (os ?? Platform.operatingSystem) == 'windows';
  final sep = windows ? r'\' : '/';
  final dataDir = envWithFallback(env, 'ANTENNA_DATA_DIR', 'X_DATA_DIR');
  if (dataDir != null) return '$dataDir$sep$socketFileName';
  // Windows: never the roaming `%APPDATA%` (keys must not follow the profile to another PC); `XDG_DATA_HOME` is not
  // read there.
  if (windows) {
    final local = env['LOCALAPPDATA'];
    final base = local != null && local.isNotEmpty ? local : '.';
    return '$base$sep$windowsDataDirName$sep$socketFileName';
  }
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return '$xdg/$dataDirName/$socketFileName';
  final home = env['HOME'] ?? '.';
  return '$home/.local/share/$dataDirName/$socketFileName';
}

/// Short form of a path for display (`~` instead of the home directory).
String prettyPath(String path, Map<String, String> env) {
  final home = env['HOME'];
  if (home != null && home.isNotEmpty && path.startsWith('$home/')) {
    return '~${path.substring(home.length)}';
  }
  return path;
}
