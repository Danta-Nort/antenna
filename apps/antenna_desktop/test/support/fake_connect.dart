// SPDX-License-Identifier: AGPL-3.0-only
// Stand-ins for Connect: an in-memory file system (the apps' configuration files, backups) and a launcher that
// records the links the window opens.

import 'package:antenna_desktop/host/app_connect.dart';

class FakeConnectorFs implements ConnectorFs {
  FakeConnectorFs([Map<String, String>? files]) : files = {...?files};

  /// Path → content.
  final Map<String, String> files;

  /// Backups made, in order (backup path → original path).
  final backups = <String, String>{};

  /// Writes, in order.
  final writes = <String>[];
  final temps = <String, List<int>>{};

  @override
  String? read(String path) => files[path];

  @override
  bool fileExists(String path) => files.containsKey(path);

  @override
  bool dirExists(String path) => files.keys.any((f) => f.startsWith('$path/'));

  @override
  String backup(String path, DateTime now) {
    final b = '$path.antenna-backup-${backupStamp(now)}';
    files[b] = files[path]!;
    backups[b] = path;
    return b;
  }

  @override
  void write(String path, String content) {
    files[path] = content;
    writes.add(path);
  }

  @override
  String writeTemp(String name, List<int> bytes) {
    final p = '/tmp/antenna-connect-test/$name';
    temps[p] = bytes;
    return p;
  }
}

class FakeAppLauncher implements AppLauncher {
  final urls = <String>[];
  final opened = <(String, String?)>[];

  /// What the system answers.
  bool ok = true;

  @override
  Future<bool> openUrl(String url) async {
    urls.add(url);
    return ok;
  }

  @override
  Future<bool> openFile(String path, {String? appPath}) async {
    opened.add((path, appPath));
    return ok;
  }

  /// App bundles that run now (`null` from [appRunning] for the others when [canTell] is false).
  final running = <String>{};
  bool canTell = true;

  /// What quitting answers; [AppQuitResult.quit] also takes the app off [running].
  AppQuitResult quitResult = AppQuitResult.quit;

  /// Restart calls in order: `quit:<path>`, `open:<path>` (checks for running are not listed).
  final appCalls = <String>[];

  @override
  Future<bool?> appRunning(String appPath) async => canTell ? running.contains(appPath) : null;

  @override
  Future<AppQuitResult> quitApp(String appPath, {Duration timeout = appQuitTimeout}) async {
    appCalls.add('quit:$appPath');
    if (quitResult == AppQuitResult.quit) running.remove(appPath);
    return quitResult;
  }

  @override
  Future<bool> openApp(String appPath) async {
    appCalls.add('open:$appPath');
    if (ok) running.add(appPath);
    return ok;
  }
}
