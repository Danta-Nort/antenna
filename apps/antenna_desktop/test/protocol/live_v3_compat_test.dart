// SPDX-License-Identifier: AGPL-3.0-only
// Compatibility of the window (x-control/2) with an x-control/3 daemon (slice 4, files; CONTROL §14): a contact sends a
// file through the CLI, and the window does not fail on the new `file` events and `kind: file` messages in history and
// the subscription, and stays in its session. The Files screen is tested elsewhere; this only checks nothing breaks.
// Run: ANTENNAD_BIN=<path to antennad> flutter test test/protocol/live_v3_compat_test.dart (`antenna` next to `antennad`).
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  // A daemon without files (x-control/2 and older) does not know `share`; this test is about x-control/3.
  final hasFiles = xCli != null &&
      File(xCli).existsSync() &&
      '${Process.runSync(xCli, ['share', '--help'], environment: ownerCliEnv(), includeParentEnvironment: false).stdout}'
          .contains('sandbox');

  test('window survives files from a contact (x-control/3 events and history items)', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket, factsEvery: const Duration(seconds: 1));
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(b, bob.password);
      await m.connect();
      expect(await m.login(alice.password), isNull);
      a.sessionToken = m.daemon.sessionToken;
      // The link.
      final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'bob', password: alice.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
        link: created.link,
        trust: 3,
        label: 'alice',
        connectTimeoutMs: 5000,
        password: bob.password,
      )));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;
      await until(() => m.contacts.isNotEmpty && m.subscribed, what: 'contact in the window');
      final link = m.contacts.single.linkId;
      await m.select(link);

      // B sends a file through the owner CLI (a script session: `antenna login --password-stdin`, then `antenna share`).
      final file = File('${root.path}/report.txt')..writeAsStringSync('quarterly report\n' * 200);
      final r = await Process.run('bash', [
        '-c',
        'printf "%s\\n" "\$PW" | "\$X" --data-dir "\$D" login --password-stdin >/dev/null && '
            '"\$X" --data-dir "\$D" --json share alice "\$F"; e=\$?; exit \$e',
        // ↑ Not the last command: otherwise bash would exec, and the parent of `antenna share` would be the test instead of
        // the script that holds the session.
        // ownerCliEnv (no ambient ANTENNA_AGENT_TOKEN), or the owner `login`/`share` runs as an agent and exits 2.
      ], environment: {...ownerCliEnv(), 'X': xCli!, 'D': bob.dir, 'PW': bob.password, 'F': file.path},
          includeParentEnvironment: false);
      print('SHARE (bob): exit ${r.exitCode} ${'${r.stdout}'.trim().split('\n').last}');
      expect(r.exitCode, 0, reason: '${r.stderr}');

      // Window A: the file offer message reaches the timeline, the window stays in its session, nothing fails.
      await until(() => m.chatOf(link).any((e) => e.text.contains('report.txt')), what: 'file message in the window');
      final e = m.chatOf(link).firstWhere((e) => e.text.contains('report.txt'));
      print('WINDOW: file message shown as "${e.text}" (kind ${e.kind.name}); phase ${m.phase.name}');
      expect(m.phase, Phase.unlocked);
      expect(m.subscribed, isTrue);
      // History and contacts can be read (the new v3 fields are tolerated).
      await m.loadHistory(link, reset: true);
      expect(m.chatOf(link).any((x) => x.text.contains('report.txt')), isTrue);
      await m.refreshContacts();
      expect(m.contacts.single.linkId, link);
    } finally {
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null || !hasFiles ? 'needs antennad/x with files (x-control/3)' : false, timeout: const Timeout(Duration(minutes: 2)));
}
