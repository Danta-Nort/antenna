// SPDX-License-Identifier: AGPL-3.0-only
// The `antenna update` client on a stand-in CLI: arguments, JSON parsing, error codes, and the install that gets the
// owner password only on stdin (never in the arguments or the environment).

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/updater.dart';
import 'package:antenna_desktop/state/updates.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_updater.dart';

void main() {
  const cli = '$appPath/Contents/Helpers/antenna';

  test('status: arguments and the parsed JSON', () async {
    final f = FakeCli(status: statusJson(updateUrl: 'https://example.com/releases/latest.json'));
    final s = await f.updater().status();
    expect(f.calls.single, [cli, 'update', '--json']);
    expect(s.current.version, '0.1.0-preview.2');
    expect(s.current.label, '0.1.0-preview.2 (47cb9fa68c07)');
    expect(s.install.kind, UpdateInstallKind.macosApp);
    expect(s.install.supported, isTrue);
    expect(s.install.path, appPath);
    expect(s.previous!.version, '0.1.0-preview.1');
    expect(s.keys.pinned, 1);
    expect(shortKeyId(s.keys.ids.single), '9f3c1a2b');
    expect(s.keys.testKey, isFalse);
    expect(s.updateUrl, 'https://example.com/releases/latest.json');
    expect(s.log, updateLog);

    f.status = statusJson(kind: 'unsupported', reason: 'Antenna runs from a read-only disk image.', previous: false);
    final u = await f.updater().status();
    expect(u.install.kind, UpdateInstallKind.unsupported);
    expect(u.install.supported, isFalse);
    expect(u.install.reason, 'Antenna runs from a read-only disk image.');
    expect(u.install.path, isNull);
    expect(u.previous, isNull);
    expect(u.updateUrl, isNull);
  });

  test('verify: --dry-run or --manifest-only, every path after --from; the result', () async {
    final f = FakeCli();
    final v = await f.updater().verify(['/d/antenna-0.1.1-manifest.json', '/d/x.sig', '/d/$dmgName']);
    expect(f.calls.last, [
      cli, 'update', '--from', '/d/antenna-0.1.1-manifest.json', '/d/x.sig', '/d/$dmgName', '--dry-run', '--json',
    ]);
    expect(v.action, 'verify');
    expect(v.release.version, '0.1.1');
    expect(v.release.channel, 'preview');
    expect(v.release.created, DateTime.utc(2026, 10, 10, 12));
    expect(v.newer, isTrue);
    expect(v.signature.valid, isTrue);
    expect(v.signature.keyIds, [releaseKeyId]);
    expect(v.asset!.name, dmgName);
    expect(v.asset!.size, 48700249);
    expect(v.asset!.path, endsWith(dmgName));
    expect(v.assets.single.blake3, dmgBlake3);
    expect(v.install!.path, appPath);
    expect(v.steps, hasLength(4));
    expect(v.installable, isTrue);

    await f.updater().verify(['/d'], manifestOnly: true);
    expect(f.calls.last, [cli, 'update', '--from', '/d', '--manifest-only', '--json']);
  });

  test('only the JSON true counts as a valid signature; not newer or no asset is not installable', () async {
    final f = FakeCli();
    final base = verifyJson();
    f.verify = (_, {required manifestOnly}) => {
          ...base,
          'signature': {'valid': 'true', 'key_ids': [releaseKeyId]},
        };
    expect((await f.updater().verify(['/d'])).signature.valid, isFalse);
    f.verify = (_, {required manifestOnly}) => verifyJson(newer: false);
    expect((await f.updater().verify(['/d'])).installable, isFalse);
    f.verify = (_, {required manifestOnly}) => verifyJson(asset: false);
    final v = await f.updater().verify(['/d'], manifestOnly: true);
    expect(v.asset, isNull);
    expect(v.installable, isFalse);
  });

  test('check: arguments, the asset URL', () async {
    final f = FakeCli(status: statusJson(updateUrl: 'https://example.com/releases/latest.json'));
    final v = await f.updater().check();
    expect(f.calls.single, [cli, 'update', '--check', '--json']);
    expect(v.action, 'check');
    expect(v.url, 'https://example.com/releases/latest.json');
    expect(v.asset!.url, 'https://example.com/releases/0.1.1/$dmgName');
  });

  test('errors: the CLI code and English message; no JSON, timeout, start failure', () async {
    final f = FakeCli()
      ..verify = (_, {required manifestOnly}) => errorJson('bad_signature', 'manifest signature does not verify');
    await expectLater(
      f.updater().verify(['/d']),
      throwsA(isA<UpdateException>()
          .having((e) => e.code, 'code', UpdateErrorCode.badSignature)
          .having((e) => e.message, 'message', 'manifest signature does not verify')),
    );

    // A CLI without `update` (clap prints usage to stderr, exit 2).
    f.reply = (_) => ProcessResult(1, 2, '', "error: unrecognized subcommand 'update'\n\nUsage: antenna <COMMAND>\n");
    await expectLater(
      f.updater().status(),
      throwsA(isA<UpdateException>()
          .having((e) => e.code, 'code', UpdateErrorCode.noResult)
          .having((e) => e.message, 'message', contains("unrecognized subcommand 'update'"))),
    );

    // runWithTimeout kills a hung command with exit code -1.
    f.reply = (_) => ProcessResult(1, -1, '', '');
    await expectLater(f.updater().status(),
        throwsA(isA<UpdateException>().having((e) => e.code, 'code', UpdateErrorCode.timeout)));

    // `ok: true` with a failing exit code is not trusted.
    f.reply = (_) => ProcessResult(1, 3, json.encode(statusJson()), '');
    await expectLater(f.updater().status(),
        throwsA(isA<UpdateException>().having((e) => e.code, 'code', UpdateErrorCode.noResult)));

    // Progress lines before the JSON on stdout are tolerated: the last object line is the result.
    f.reply = (_) => ProcessResult(1, 0, 'Checking…\n${json.encode(statusJson())}\n', '');
    expect((await f.updater().status()).current.version, '0.1.0-preview.2');

    final missing = AntennaUpdater(cliPath: '/nonexistent/antenna');
    await expectLater(missing.status(),
        throwsA(isA<UpdateException>().having((e) => e.code, 'code', UpdateErrorCode.startFailed)));
  });

  // The starter takes only (exe, args): the process inherits the window's environment, so the password cannot reach
  // the environment either.
  test('install: started detached; the password goes only to stdin, then stdin is closed', () async {
    const password = 'correct horse battery staple';
    String? seen;
    final f = FakeCli()
      ..install = (pw) {
        seen = pw;
        return installJson();
      };
    final r = await f.updater().install(['/d/antenna-0.1.1-manifest.json'], password);
    final args = f.calls.single;
    expect(args, [cli, 'update', '--from', '/d/antenna-0.1.1-manifest.json', '--yes', '--password-stdin', '--json']);
    expect(args.any((a) => a.contains(password)), isFalse, reason: 'never in the arguments');
    expect(f.started.single.stdinText, '$password\n');
    expect(seen, password);
    expect(r.from.version, '0.1.0-preview.2');
    expect(r.to.version, '0.1.1');
    expect(r.daemonRestarted, isTrue);
    expect(r.appRelaunched, isFalse);
    expect(r.keysLocked, isTrue);
    expect(r.log, updateLog);
  });

  test('install: the error the CLI prints before it quits the window', () async {
    final f = FakeCli()..install = (_) => errorJson('wrong_password', 'wrong owner password');
    await expectLater(
      f.updater().install(['/d'], 'nope'),
      throwsA(isA<UpdateException>().having((e) => e.code, 'code', UpdateErrorCode.wrongPassword)),
    );
  });

  test('a real detached process: the script reads the password line from stdin; args and env stay clean', () async {
    final dir = Directory.systemTemp.createTempSync('updater-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File('${dir.path}/antenna');
    final seen = '${dir.path}/seen';
    script.writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$@" > "$seen.args"
env > "$seen.env"
echo "Stopping the daemon…" >&2
if [ "\$2" != "--from" ]; then
  echo '${json.encode(statusJson())}'
  exit 0
fi
IFS= read -r pw
printf '%s' "\$pw" > "$seen.pw"
if [ "\$pw" = "s3cret pass" ]; then
  echo '${json.encode(installJson())}'
else
  echo '${json.encode(errorJson('wrong_password', 'wrong owner password'))}'
  exit 1
fi
''');
    Process.runSync('chmod', ['+x', script.path]);
    final u = AntennaUpdater(cliPath: script.path);

    expect((await u.status()).current.version, '0.1.0-preview.2', reason: 'runWithTimeout + JSON on stdout');

    final r = await u.install(['/d'], 's3cret pass');
    expect(r.to.version, '0.1.1');
    expect(File('$seen.pw').readAsStringSync(), 's3cret pass');
    expect(File('$seen.args').readAsStringSync(), 'update\n--from\n/d\n--yes\n--password-stdin\n--json\n');
    expect(File('$seen.env').readAsStringSync(), isNot(contains('s3cret')));

    await expectLater(u.install(['/d'], 'wrong'),
        throwsA(isA<UpdateException>().having((e) => e.code, 'code', UpdateErrorCode.wrongPassword)));
  }, testOn: 'posix');

  group('release manifests among files', () {
    test('file names', () {
      expect(releaseManifestVersion('antenna-0.1.1-manifest.json'), '0.1.1');
      expect(releaseManifestVersion('antenna-1.2.0-manifest.json'), '1.2.0');
      expect(releaseManifestVersion('antenna-0.1.1-manifest.json.sig'), isNull);
      expect(releaseManifestVersion('Antenna-0.1.0-manifest.json'), isNull);
      expect(releaseManifestVersion('antenna-latest-manifest.json'), isNull);
      expect(releaseManifestVersion('report.pdf'), isNull);
    });

    test('checked once per path; only a valid signature counts; assets by BLAKE3', () async {
      final f = FakeCli();
      final checks = ManifestChecks(f.updater());
      const good = '/links/emily/shared/antenna-0.1.1-manifest.json';
      const bad = '/links/ryan/inbox/antenna-0.1.1-manifest.json';
      f.verify = (paths, {required manifestOnly}) {
        expect(manifestOnly, isTrue);
        return paths.single == good ? verifyJson(asset: false) : errorJson('bad_signature');
      };
      var notified = 0;
      checks.addListener(() => notified++);
      expect(checks.verified(good), isNull, reason: 'not checked yet');
      expect(checks.verified(good), isNull);
      expect(checks.verified(bad), isNull);
      await pumpEventQueue();
      expect(f.calls, hasLength(2), reason: 'one CLI call per path');
      expect(notified, 2);
      expect(checks.verified(good)!.release.version, '0.1.1');
      expect(checks.verified(bad), isNull);
      expect(checks.releaseWithAsset(dmgBlake3.toUpperCase())!.release.version, '0.1.1');
      expect(checks.releaseWithAsset('00ff'), isNull);
      expect(checks.releaseWithAsset(''), isNull);
      expect(f.calls, hasLength(2));
    });
  });
}
