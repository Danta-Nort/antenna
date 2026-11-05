// SPDX-License-Identifier: AGPL-3.0-only
// x-control/7 against a REAL daemon (D-103, CONTROL §23 and §14), through the window's own model: "Install signed
// updates by itself" (the status, the owner password both ways, nothing staged, a development build that cannot replace
// itself, no `status.updated` on a daemon that was not updated); and received files whose name is taken (the same
// content accepted without a second copy, `duplicate`; another file under the name saved as `report (2).txt`, D-128; an
// invalid name). Skipped with the reason while the daemon answers these commands `not_implemented` or does not know
// them (a daemon older than v7).
// Run: ANTENNAD_BIN=<path to antennad> flutter test --tags live test/protocol/live_update_auto_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 40), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// The daemon has not built [cmd] yet (or is older than v7): the reason to skip, or `null`.
String? notThere(Object e, String cmd) => e is XControlException &&
        (e.code == XErrorCode.notImplemented || e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest)
    ? 'the daemon does not answer `$cmd` yet (${e.code}): run against the D-103 daemon'
    : null;

void main() {
  final antennad = findXd();

  test('update_auto: off by default, the password both ways, nothing staged; no status.updated', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    await alice.start();
    final a = XControlClient(alice.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket, live: false);
    try {
      await a.init(alice.password);
      await m.connect();
      expect(await m.login(alice.password), isNull);
      try {
        await m.daemon.updateAutoStatus();
      } on XControlException catch (e) {
        final why = notThere(e, 'update_auto_status');
        if (why != null) {
          markTestSkipped(why);
          return;
        }
        rethrow;
      }
      expect(m.hello?.proto, 'x-control/7');
      expect(m.status?.updated, isNull, reason: 'this daemon did not come up from an automatic update');
      await m.refreshUpdateAuto();
      final first = m.updateAuto!;
      print('UPDATE_AUTO: enabled ${first.enabled}, supported ${first.supported} (${first.unsupportedReason}), '
          'keys_kept ${first.keysKept}, url ${first.url}');
      expect(first.enabled, isFalse, reason: 'off by default');
      expect(first.staged, isNull);

      final wrong = await m.setUpdateAuto(enabled: true, auth: const PasswordAuth('not the password'));
      expect(wrong, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword));
      final on = await m.setUpdateAuto(enabled: true, auth: PasswordAuth(alice.password));
      if (first.supported) {
        expect(on, isNull);
        expect((m.updateAuto!.enabled, m.updateAuto!.keysKept), (true, true));
        final offWrong = await m.setUpdateAuto(enabled: false, auth: const PasswordAuth('not the password'));
        expect(offWrong, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword),
            reason: 'turning it off needs the password too');
        expect(await m.setUpdateAuto(enabled: false, auth: PasswordAuth(alice.password)), isNull);
        expect(m.updateAuto!.enabled, isFalse);
      } else {
        // A development build from target/: the daemon says why it cannot replace itself.
        expect(on, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.unsupportedInstall));
        print('UNSUPPORTED: ${(on! as XControlException).message}');
        await m.refreshUpdateAuto();
        expect(m.updateAuto!.enabled, isFalse);
      }
      expect(await m.updateAutoNow(), isA<XControlException>().having((e) => e.code, 'code', XErrorCode.notFound));
      expect(await m.updateAutoLater(), isA<XControlException>().having((e) => e.code, 'code', XErrorCode.notFound));
    } finally {
      m.dispose();
      await alice.stop();
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 2)));

  test('a name that is taken: the same file accepted without a copy; another one saved under the next number',
      () async {
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
      final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'bob', password: alice.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
          link: created.link, trust: 3, label: 'alice', connectTimeoutMs: 5000, password: bob.password)));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;
      await until(() => m.contacts.isNotEmpty && m.subscribed, what: 'contact in the window');

      // The same report twice (a re-send), then a different file under the same name.
      final same = Directory('${root.path}/same')..createSync();
      final other = Directory('${root.path}/other')..createSync();
      // Numbered lines: repeated words would look like a seed phrase to the secret scanner.
      final r1 = File('${same.path}/report.txt')
        ..writeAsStringSync([for (var i = 1; i <= 40; i++) 'Line $i: ${i * 37} units shipped'].join('\n'));
      final r2 = File('${other.path}/report.txt')
        ..writeAsStringSync([for (var i = 1; i <= 40; i++) 'Row $i: ${i * 11} units returned'].join('\n'));
      final s1 = await b.shareFile('alice', r1.path);
      final s2 = await b.shareFile('alice', r1.path);
      final s3 = await b.shareFile('alice', r2.path);
      await until(() => [s1, s2, s3].every((s) => m.files[s.id]?.state == 'checked'), what: 'three files checked');

      try {
        await m.daemon.fileNameCheck(s1.id);
      } on XControlException catch (e) {
        final why = notThere(e, 'file_name_check');
        if (why != null) {
          markTestSkipped(why);
          return;
        }
        rethrow;
      }
      expect((await m.checkFileName(s1.id))!.state, 'free');
      expect(await m.acceptFile(s1.id), isNull);
      expect(m.files[s1.id]!.duplicate, isFalse);

      final c2 = (await m.checkFileName(s2.id))!;
      expect(c2.state, 'same_file');
      expect(await m.acceptFile(s2.id), isNull, reason: 'one click, no new name needed');
      final f2 = m.files[s2.id]!;
      expect((f2.state, f2.duplicate, f2.savedAs), ('accepted', true, 'report.txt'));
      final shared = Directory('${alice.dir}/links/bob/shared');
      expect(shared.listSync().map((e) => e.path.split('/').last).toList(), ['report.txt'], reason: 'no second copy');

      final c3 = (await m.checkFileName(s3.id))!;
      print('TAKEN: ${c3.state}, suggestion ${c3.suggestion}, message ${c3.message}');
      expect(c3.state, 'taken');
      expect(c3.suggestion, 'report (2).txt');
      expect((await m.checkFileName(s3.id, name: 'REPORT.TXT'))!.state, 'taken', reason: 'ignoring case');
      expect((await m.checkFileName(s3.id, name: 'a/b.txt'))!.state, 'invalid');
      expect((await m.checkFileName(s3.id, name: c3.suggestion))!.state, 'free');
      // A taken name the owner chose is refused; without one the daemon saves under the next number (D-128).
      final refused = await m.acceptFile(s3.id, name: 'REPORT.TXT');
      expect(refused, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.fileNameTaken));
      expect(await m.acceptFile(s3.id), isNull);
      expect(m.files[s3.id]!.savedAs, 'report (2).txt');
      expect(m.files[s3.id]!.renamed, isTrue);
      expect(File('${shared.path}/report (2).txt').readAsStringSync(), r2.readAsStringSync());
      expect(File('${shared.path}/report.txt').readAsStringSync(), r1.readAsStringSync(), reason: 'untouched');
      // The sender's node gets the number in the receipt (`file-saved-as/0`).
      int? number;
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (number == null && DateTime.now().isBefore(deadline)) {
        final h = await b.history('alice', limit: 50);
        number = h.messages
            .where((x) => x.receipt?.action == 'accept_file' && x.receipt!.refs.contains(s3.messageId))
            .map((x) => x.receipt!.nameNumber)
            .firstOrNull;
        if (number == null) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(number, 2, reason: 'the receipt with the number at the sender');
    } finally {
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 3)));
}
