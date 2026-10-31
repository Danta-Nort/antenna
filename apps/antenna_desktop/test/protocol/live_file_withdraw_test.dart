// SPDX-License-Identifier: AGPL-3.0-only
// Withdrawing a sent file against two real daemons (preview.5, CONTROL §14): the window sends a file from the composer
// and withdraws it before the contact answers (the contact's node deletes its pending copy and tells its owner); the
// contact withdraws a file it sent and the window shows it withdrawn, also from the history receipt; a file the
// contact has accepted cannot be withdrawn (`not_found`).
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_file_withdraw_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
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

/// [b]'s copy of a file named [name], once its check is done.
Future<FileInfo> checkedAt(XDaemon b, String name) async {
  final sw = Stopwatch()..start();
  while (true) {
    final f = (await b.filesPending()).where((f) => f.name == name).firstOrNull;
    if (f?.state == 'checked') return f!;
    if (sw.elapsed > const Duration(seconds: 40)) throw TimeoutException('$name checked at the contact');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  final antennad = findXd();
  final cli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final hasWithdraw = cli != null &&
      File(cli).existsSync() &&
      Process.runSync(cli, ['files', 'withdraw', '--help'],
              environment: ownerCliEnv(), includeParentEnvironment: false)
          .exitCode ==
          0;

  test('withdraw: the window\'s file, the contact\'s file, and an answered one', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket, factsEvery: const Duration(seconds: 1));
    XDialog? bobSession;
    Events? bobEvents;
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      bobSession = await openOwnerSession(b, bob.password);
      await m.connect();
      expect(await m.login(alice.password), isNull);
      a.sessionToken = m.daemon.sessionToken;
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
      bobEvents = Events(b.subscribe());

      // 1. The window sends a file from the composer and withdraws it before bob answers.
      final plan = File('${root.path}/plan.txt')..writeAsStringSync('plan: ship the beta\n');
      final staging = OutgoingStaging('${root.path}/staging');
      m.stageAttachment(link, await staging.stageFile(plan.path));
      expect(await m.sendStaged(link), isTrue);
      final mine = m.filesOfLink(link).firstWhere((f) => !f.incoming && f.name == 'plan.txt');
      final atBob = await checkedAt(b, 'plan.txt');
      await m.refreshContacts();
      final c = m.contacts.single;
      print('PEER: peer_file_withdraw ${c.peerFileWithdraw}');
      expect(await m.withdrawFile(mine), isNull);
      final w = m.files[mine.id]!;
      print('WITHDRAWN: state ${w.state}, withdrawal ${w.withdrawal}');
      expect(w.state, 'withdrawn');
      expect(w.withdrawal, c.peerFileWithdraw ? 'contact_notified' : 'contact_cannot_withdraw');
      expect(c.peerFileWithdraw, isTrue, reason: 'two nodes of this build learn file-withdraw/0 on connection');
      final ev = await bobEvents.next<FileEvent>((e) => e.file.id == atBob.id && e.file.state == 'withdrawn',
          const Duration(seconds: 40));
      expect(ev.file.state, 'withdrawn');
      expect((await b.filesPending()).where((f) => f.id == atBob.id), isEmpty, reason: 'bob\'s copy is gone');

      // 2. Bob withdraws a file he sent before the window answered it.
      final draft = File('${root.path}/draft.txt')..writeAsStringSync('draft contract\n' * 50);
      final sent = await b.shareFile('alice', draft.path);
      await until(() => m.files[sent.id]?.state == 'checked', what: 'draft checked in the window');
      final back = await b.fileWithdraw(sent.id);
      expect(back.state, 'withdrawn');
      await until(() => m.files[sent.id]?.state == 'withdrawn', what: 'the window sees the withdrawal');
      expect(m.filesAwaiting.where((f) => f.id == sent.id), isEmpty);
      // After a reload the daemon no longer lists it; the history receipt still makes it a withdrawn card.
      final offer = m.files[sent.id]!.messageId!;
      await m.refreshFiles();
      expect(m.files[sent.id], isNull, reason: 'bob withdrew it, this node deleted its copy');
      await m.loadHistory(link, reset: true);
      print('RELOAD: ${m.fileByMessage(offer)?.state}');
      expect(m.fileByMessage(offer)?.state, 'withdrawn');
      expect(m.fileByMessage(offer)?.name, 'draft.txt');

      // 3. A file bob has accepted: nothing to withdraw.
      final notes = File('${root.path}/notes.txt')..writeAsStringSync('notes\n');
      m.stageAttachment(link, await staging.stageFile(notes.path));
      expect(await m.sendStaged(link), isTrue);
      final mine2 = m.filesOfLink(link).firstWhere((f) => !f.incoming && f.name == 'notes.txt');
      final atBob2 = await checkedAt(b, 'notes.txt');
      expect((await b.fileAccept(atBob2.id)).state, 'accepted');
      await until(() => m.files[mine2.id]?.state == 'accepted', what: 'the window sees the acceptance');
      final err = await m.withdrawFile(m.files[mine2.id]!);
      expect(err, isA<XControlException>());
      expect((err! as XControlException).code, XErrorCode.notFound);
    } on TimeoutException {
      print('ALICE LOG:\n${alice.log}\nBOB LOG:\n${bob.log}');
      rethrow;
    } finally {
      m.dispose();
      await bobEvents?.close();
      await bobSession?.cancel();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null || !hasWithdraw ? 'needs antennad with file_withdraw (preview.5)' : false,
      timeout: const Timeout(Duration(minutes: 3)));
}
