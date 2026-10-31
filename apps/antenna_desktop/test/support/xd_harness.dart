// SPDX-License-Identifier: AGPL-3.0-only
// Real `antennad` daemons for client tests: one data dir per node, no relay, 127.0.0.1 only, the same way as
// crates/antenna-cli/tests/common/mod.rs. Binary: `ANTENNAD_BIN` (the old `XD_BIN` is a fallback) or
// `<repo>/target/debug/antennad`
// (build it with `export PATH=$HOME/.cargo/bin:$PATH; nice -n 10 cargo build -p antennad` at the repository root).

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/host/daemon_host.dart' show withoutInheritedFds;

/// Path to `antennad`, or `null` if there is none (the tests are then skipped with an explanation).
String? findXd() {
  final e = Platform.environment;
  final env = (e['ANTENNAD_BIN'] ?? '').isNotEmpty ? e['ANTENNAD_BIN'] : e['XD_BIN'];
  if (env != null && env.isNotEmpty) return File(env).existsSync() ? env : null;
  // flutter test runs from the app directory: apps/antenna_desktop → repository root.
  final repo = Directory.current.parent.parent.path;
  final p = '$repo/target/debug/antennad';
  return File(p).existsSync() ? p : null;
}

const String noXdReason = 'antennad binary not found: set ANTENNAD_BIN or build it '
    '(`nice -n 10 cargo build -p antennad` in the repository root)';

/// Environment for a capability probe that runs the owner CLI (`antenna … --help`). An ambient `ANTENNA_AGENT_TOKEN`
/// (or `*_FILE`) turns the CLI into an agent, where the owner subcommands "do not exist" and their `--help` exits
/// non-zero — which a probe then misreads as a missing daemon capability and skips the test. Dropping those variables
/// (and `ANTENNA_SOCKET`, which a probe should not touch either) keeps the probe honest regardless of the shell it
/// inherits. Pass with `includeParentEnvironment: false` so the variables are really gone, not merely re-set.
Map<String, String> ownerCliEnv() => {
      for (final e in Platform.environment.entries)
        if (e.key != 'ANTENNA_AGENT_TOKEN' && e.key != 'ANTENNA_AGENT_TOKEN_FILE' && e.key != 'ANTENNA_SOCKET')
          e.key: e.value,
    };

/// One node: an `antennad` process and its directory.
final class XdNode {
  XdNode(this.name, this.root, this.antennad, {this.extraArgs = const [], this.env = const {}})
      : dir = '${root.path}/$name';

  final String name;
  final Directory root;
  final String antennad;
  final String dir;

  /// More `antennad` arguments (for example the test-only `--approval-ttl-ms`).
  final List<String> extraArgs;

  /// More environment for `antennad` (for example `ANTENNA_OWNER_TEST_KEY=1`, honoured by debug builds only).
  final Map<String, String> env;
  Process? _proc;
  final StringBuffer log = StringBuffer();

  String get socket => '$dir/antennad.sock';
  String get password => 'password-of-$name-123';

  Future<void> start() async {
    // Like the window: no descriptors inherited from flutter_tester (otherwise the antenna-files worker is not isolated).
    final (exe, args) = withoutInheritedFds(antennad, [
      '--data-dir',
      dir,
      '--relay',
      'disabled',
      '--bind-ip',
      '127.0.0.1',
      '--retry-max-ms',
      '1000',
      '--dial-timeout-ms',
      '3000',
      ...extraArgs,
    ]);
    final p = await Process.start(exe, args, environment: {
      'ANTENNAD_LOG': Platform.environment['ANTENNAD_LOG'] ?? 'warn,antenna_core=info,antennad=info',
      // Link folders (x-control/3, files) go to a temporary directory, not ~/Antenna/links.
      'ANTENNA_LINKS_DIR': '$dir/links',
      ...env,
    });
    _proc = p;
    p.stderr.listen((b) => log.write(String.fromCharCodes(b)));
    unawaited(p.stdout.drain<void>());
    final sw = Stopwatch()..start();
    while (FileSystemEntity.typeSync(socket) == FileSystemEntityType.notFound) {
      if (sw.elapsed > const Duration(seconds: 30)) {
        throw StateError('antennad $name did not start: $log');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    if (p == null) return;
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 15), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
  }
}

/// Temporary root for the test's nodes (a short path: unix socket paths are limited to ~108 bytes).
Future<Directory> tempRoot() => Directory('/tmp').createTemp('xdesk-');
