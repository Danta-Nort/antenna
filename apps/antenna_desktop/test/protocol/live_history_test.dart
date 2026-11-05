// SPDX-License-Identifier: AGPL-3.0-only
// x-control/2 against REAL `antennad`, through the window state (two windows, one per node): "History verified" with
// the same fingerprint on both sides, unread and mark_read, renaming, a database rollback from a "backup" → rekey with
// two codes (each owner types the other's code) → "verified" again, deleting the link.
// Run: ANTENNAD_BIN=<path to antennad> flutter test test/protocol/live_history_test.dart
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

Future<void> until(FutureOr<bool> Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> sendDelivered(XControlClient c, String to, String text) async {
  final r = await c.send(to, text, wait: const Duration(seconds: 15));
  if (r.delivered) return;
  await until(() async => (await c.contacts()).single.outbox == 0, timeout: const Duration(seconds: 45), what: 'delivered: $text');
}

void main() {
  final antennad = findXd();

  test('history verified, unread, rename, rollback → rekey with two codes, revoke', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final models = <AppModel>[];
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(a, alice.password);
      await openOwnerSession(b, bob.password);
      // The link (A types the code as read out by B, on the monitoring connection).
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

      // Two windows (each with its own session, in the same process).
      final ma = AppModel(connector: XControlClient.new, socketPath: alice.socket, factsEvery: const Duration(seconds: 1));
      var mb = AppModel(connector: XControlClient.new, socketPath: bob.socket, factsEvery: const Duration(seconds: 1));
      models.addAll([ma, mb]);
      await ma.connect();
      await mb.connect();
      expect(ma.phase, Phase.loginRequired, reason: 'keys are open, the window has no session yet');
      expect(await ma.login(alice.password), isNull);
      expect(await mb.login(bob.password), isNull);
      await until(() => ma.subscribed && mb.subscribed, what: 'subscriptions');
      final link = ma.selectedLinkId!;

      // Messages → "History verified", with the same fingerprint on both sides.
      await ma.send('a1');
      await b.send('alice', 'b1');
      await ma.verify(link);
      await mb.verify(link);
      await until(
        () => (ma.contactById(link)?.history?.verified ?? false) && (mb.contactById(link)?.history?.verified ?? false),
        what: 'verified on both sides',
      );
      final fa = ma.contactById(link)!.history!;
      final fb = mb.contactById(link)!.history!;
      print('VERIFIED: A ${fa.fingerprint} (${fa.fingerprintDigits}) · B ${fb.fingerprint} (${fb.fingerprintDigits})');
      expect(fa.fingerprintDigits, fb.fingerprintDigits);
      expect(fa.fingerprint, isNotNull);

      // Unread: B has not opened the chat with A, so incoming messages pile up; selecting the link → mark_read.
      mb.selectedLinkId = null;
      await ma.send('a2 unread');
      await until(() => mb.contactById(link)!.unread >= 1, what: 'unread at B');
      expect((await b.contacts()).single.unread, mb.contactById(link)!.unread);
      await mb.select(link);
      await until(() async => (await b.contacts()).single.unread == 0, what: 'mark_read at B');
      print('UNREAD: B had ${fb.counts} counts; after select → mark_read → 0');

      // Renaming is local only and needs no password.
      expect(await ma.rename(link, 'Bobby'), isNull);
      expect(ma.contactById(link)!.label, 'Bobby');
      expect((await a.contacts()).single.label, 'Bobby');
      expect((await b.contacts()).single.label, 'alice', reason: 'labels are local');

      // "Yesterday's backup": a copy of B's database, then more messages, then restoring the database → a rollback on B.
      mb.dispose();
      models.remove(mb);
      await bob.stop();
      final db = File('${bob.dir}/antenna.db');
      final backup = File('${root.path}/bob-antenna.db.backup');
      db.copySync(backup.path);
      await bob.start();
      expect(await b.unlock(bob.password), DaemonState.unlocked);
      await openOwnerSession(b, bob.password);
      // Delivery must finish before the "backup" is restored: under load the connection after a restart does not come up
      // at once, so wait until the sender's queue is empty.
      await sendDelivered(b, 'alice', 'b2 after backup');
      await sendDelivered(a, 'Bobby', 'a3 after backup');
      await bob.stop();
      backup.copySync(db.path);
      for (final ext in ['antenna.db-wal', 'antenna.db-shm']) {
        final f = File('${bob.dir}/$ext');
        if (f.existsSync()) f.deleteSync();
      }
      await bob.start();
      mb = AppModel(connector: XControlClient.new, socketPath: bob.socket, factsEvery: const Duration(seconds: 1));
      models.add(mb);
      await mb.connect();
      expect(mb.phase, Phase.locked);
      expect(await mb.unlock(bob.password), isNull, reason: 'one password: keys and session');
      await until(() => mb.subscribed, what: 'B subscription');
      final hb = mb.contactById(link)!.history!;
      print('ROLLBACK at B: state=${hb.state} rollback=${hb.rollback} send_blocked=${hb.sendBlocked}');
      expect(hb.rolledBack, isTrue);
      expect(hb.sendBlocked, isTrue);
      await mb.select(link);
      await mb.send('from the past');
      expect(mb.chatOf(link).last.error, XErrorCode.rekeyRequired);
      await ma.verify(link);
      await until(() => ma.contactById(link)?.history?.peerRolledBack ?? false, what: 'peer_rolled_back at A');

      // Rekey: B proposes (password) → code #1; A types it (password) → code #2; B types code #2 → done.
      expect(await mb.rekey(link, PasswordAuth(bob.password)), isNull);
      final f1 = mb.rekeyOf(link);
      expect(f1.stage, RekeyStage.myCodeShown);
      final code1 = f1.code!;
      await until(() => ma.rekeys[link]?.stage == RekeyStage.enterFirstCode, what: 'A: requested_by_contact');
      final wrong = ((int.parse(code1) + 1) % 1000000).toString().padLeft(6, '0');
      expect(await ma.rekey(link, PasswordAuth(alice.password), code: wrong), isA<XControlException>());
      expect(ma.rekeys[link]!.error, isA<XControlException>().having((e) => e.code, 'code', XErrorCode.sasMismatch));
      final names = digitGlyphs(code1)!.map((g) => g.emoji).join(); // A types it as animals
      expect(await ma.rekey(link, PasswordAuth(alice.password), code: names), isNull);
      final f2 = ma.rekeys[link]!;
      expect(f2.stage, RekeyStage.secondCodeShown);
      final code2 = f2.code!;
      expect(code2, isNot(code1));
      await until(() => mb.rekeyOf(link).stage == RekeyStage.enterSecondCode, what: 'B: confirm_contact_code');
      final sw = Stopwatch()..start();
      expect(await mb.rekey(link, PasswordAuth(bob.password), code: code2), isNull);
      expect(mb.rekeyOf(link).stage, RekeyStage.done);
      await until(() => ma.rekeys[link]?.stage == RekeyStage.done, what: 'A: rekey done');
      await mb.verify(link);
      await until(() => mb.contactById(link)?.history?.verified ?? false, what: 'B verified after rekey');
      print('REKEY: two codes, done and history verified again ${sw.elapsedMilliseconds} ms after the second code');
      b.sessionToken = mb.daemon.sessionToken; // daemon B restarted: use the session window B opened
      await sendDelivered(b, 'alice', 'after rekey');

      // Delete the link (password), history included.
      expect(await ma.revoke(link, const PasswordAuth('wrong-password')), isA<XControlException>());
      expect(await ma.revoke(link, PasswordAuth(alice.password), deleteHistory: true), isNull);
      expect(ma.contacts, isEmpty);
      expect(await a.contacts(), isEmpty);
      print('REVOKE: link removed at A');
    } finally {
      for (final m in models) {
        m.dispose();
      }
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 3)));
}
