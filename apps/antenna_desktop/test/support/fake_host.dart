// SPDX-License-Identifier: AGPL-3.0-only
// A stand-in daemon "host" for widget tests and first-launch screenshots.

import 'dart:async';

import 'package:antenna_desktop/host/daemon_host.dart';

import 'fake_daemon.dart';

class FakeHost implements DaemonHost {
  FakeHost(this.daemon, {this.fail, this.hang = false, this.outlives = true});

  final FakeDaemon daemon;

  /// Start error (the "daemon didn't start" screen).
  final DaemonStartException? fail;

  /// Start never finishes (the "Starting the daemon…" screen).
  final bool hang;
  final bool outlives;
  int starts = 0;
  int stops = 0;

  @override
  String get kind => 'fake';
  @override
  bool get outlivesWindow => outlives;
  @override
  String get xdPath => '/Applications/Antenna.app/Contents/Helpers/antennad';
  @override
  String get logPath => '/Users/owner/Library/Logs/Antenna/antennad.log';

  @override
  Future<void> start() async {
    starts++;
    if (hang) return Completer<void>().future;
    if (fail != null) throw fail!;
    daemon.reachable = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    daemon.reachable = false;
  }

  @override
  Future<void> onWindowExit() async {
    if (!outlives) await stop();
  }
}
