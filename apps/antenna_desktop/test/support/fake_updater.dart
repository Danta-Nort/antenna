// SPDX-License-Identifier: AGPL-3.0-only
// A stand-in for `antenna update --json` (the CLI is not run in widget, host and golden tests): canned JSON in the
// CLI's shapes, a runner that records the arguments, and a detached install process that records its stdin.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/updater.dart';

const releaseKeyId = '9f3c1a2b7d5e40c1aa0e5b16c2d9e8f7';
const appPath = '/Applications/Antenna.app';
const updateLog = '/Users/owner/Library/Logs/Antenna/update.log';
const dmgName = 'Antenna-0.1.1-macos-arm64.dmg';
const dmgBlake3 = 'b3a5e7c90d1f2a4b6c8d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d';

Map<String, Object?> statusJson({
  String? updateUrl,
  String kind = 'macos_app',
  String? reason,
  int pinned = 1,
  bool testKey = false,
  bool previous = true,
}) =>
    {
      'ok': true,
      'action': 'status',
      'current': {'version': '0.1.0-preview.2', 'commit': '47cb9fa68c07'},
      'install': {'kind': kind, 'path': kind == 'unsupported' ? null : appPath, 'reason': reason},
      'previous': previous ? {'version': '0.1.0-preview.1', 'commit': '1c63cc92d7bf'} : null,
      'keys': {'pinned': pinned, 'ids': pinned == 0 ? <String>[] : [releaseKeyId], 'test_key': testKey},
      'update_url': updateUrl,
      'log': updateLog,
    };

Map<String, Object?> _asset({String? path, String? url}) => {
      'name': dmgName,
      'os': 'macos',
      'arch': 'arm64',
      'kind': 'app',
      'size': 48700249,
      'sha256': '5d41402abc4b2a76b9719d911017c592ae2f6e4b9a0c1d2e3f405162738495a6',
      'blake3': dmgBlake3,
      'path': ?path,
      'url': ?url,
    };

Map<String, Object?> verifyJson({
  String dir = '/Users/owner/Downloads/antenna-0.1.1',
  bool valid = true,
  bool newer = true,
  bool asset = true,
  bool testKey = false,
  String action = 'verify',
}) =>
    {
      'ok': true,
      'action': action,
      'current': {'version': '0.1.0-preview.2', 'commit': '47cb9fa68c07'},
      'update': {
        'version': '0.1.1',
        'channel': 'preview',
        'commit': '8e21d04b5a9f',
        'created': '2026-10-10T12:00:00Z',
        'manifest': '$dir/antenna-0.1.1-manifest.json',
      },
      'newer': newer,
      'signature': {'valid': valid, 'key_ids': [releaseKeyId], 'test_key': testKey},
      'assets': [_asset()],
      'asset': asset
          ? _asset(
              path: action == 'verify' ? '$dir/$dmgName' : null,
              url: action == 'check' ? 'https://example.com/releases/0.1.1/$dmgName' : null,
            )
          : null,
      'install': {'kind': 'macos_app', 'path': appPath, 'reason': null},
      'steps': [
        'Mount the disk image read-only',
        'Stop the daemon',
        'Replace $appPath (the old copy is kept for a rollback)',
        'Start the daemon and the window again',
      ],
      'log': updateLog,
      if (action == 'check') 'url': 'https://example.com/releases/latest.json',
    };

Map<String, Object?> installJson() => {
      'ok': true,
      'action': 'install',
      'from': {'version': '0.1.0-preview.2', 'commit': '47cb9fa68c07'},
      'to': {'version': '0.1.1', 'commit': '8e21d04b5a9f'},
      'daemon': {'restarted': true, 'how': 'child', 'note': null},
      'app': {'relaunched': false},
      'keys_locked': true,
      'log': updateLog,
    };

Map<String, Object?> errorJson(String code, [String message = 'something went wrong']) =>
    {'ok': false, 'error': code, 'message': message, 'command': 'update'};

/// The CLI as a function of its arguments: a JSON object (exit 0 when `ok`, 1 otherwise) or a whole [ProcessResult].
typedef FakeCliReply = Object Function(List<String> args);

/// Runs the "CLI" in memory and records every call.
final class FakeCli {
  FakeCli({Map<String, Object?>? status, this.verify, this.check, this.install, this.reply})
      : status = status ?? statusJson();

  Map<String, Object?> status;
  Map<String, Object?> Function(List<String> paths, {required bool manifestOnly})? verify;
  Map<String, Object?> Function()? check;

  /// The install result for the password the process read from stdin.
  Map<String, Object?> Function(String password)? install;

  /// Overrides everything above (for odd outputs).
  FakeCliReply? reply;

  /// While set and not completed, the install process does not answer (the window shows "Installing…").
  Completer<void>? hold;

  final List<List<String>> calls = [];
  final List<FakeInstallProcess> started = [];

  Object _answer(List<String> args) {
    if (reply != null) return reply!(args);
    if (args.contains('--check')) return (check ?? () => verifyJson(action: 'check'))();
    final from = args.indexOf('--from');
    if (from >= 0) {
      final paths = args.skip(from + 1).takeWhile((a) => !a.startsWith('--')).toList();
      final manifestOnly = args.contains('--manifest-only');
      return (verify ?? (p, {required manifestOnly}) => verifyJson())(paths, manifestOnly: manifestOnly);
    }
    return status;
  }

  Future<ProcessResult> run(String exe, List<String> args, {required Duration timeout}) async {
    calls.add([exe, ...args]);
    final a = _answer(args);
    if (a is ProcessResult) return a;
    final j = a as Map<String, Object?>;
    return ProcessResult(1, j['ok'] == true ? 0 : 1, json.encode(j), 'progress on stderr\n');
  }

  Future<Process> start(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    final p = FakeInstallProcess((pw) => json.encode((install ?? (_) => installJson())(pw)), hold: hold?.future);
    started.add(p);
    return p;
  }

  AntennaUpdater updater({String cliPath = '$appPath/Contents/Helpers/antenna'}) =>
      AntennaUpdater(cliPath: cliPath, runner: run, starter: start);
}

/// A detached install process: reads stdin to the end (the CLI reads the password line), then prints its JSON and
/// exits. A detached process has no exit code.
final class FakeInstallProcess implements Process {
  FakeInstallProcess(String Function(String password) respond, {Future<void>? hold}) {
    _in.stream.transform(utf8.decoder).join().then((s) async {
      stdinText = s;
      if (hold != null) await hold;
      _out.add(utf8.encode(respond(s.endsWith('\n') ? s.substring(0, s.length - 1) : s)));
      _err.add(utf8.encode('Stopping the daemon…\n'));
      await Future.wait([_out.close(), _err.close()]);
    });
  }

  final _in = StreamController<List<int>>();
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();

  /// Everything the window wrote to stdin.
  String? stdinText;

  @override
  late final IOSink stdin = IOSink(_in);

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  Future<int> get exitCode => throw StateError('Process is detached');

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}
