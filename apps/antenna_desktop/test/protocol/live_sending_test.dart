// SPDX-License-Identifier: AGPL-3.0-only
// Sending from the window against real antennad: (1) a text over 64 KiB is refused as `text_too_long` with the sizes in
// the daemon's words, then goes as a `.txt` file named after its first line, which the contact receives whole; (2) a
// sent image keeps the window's own preview copy after the original file is deleted (the macOS screenshot case): the
// daemon's FileInfo says image/png by signature, and the copy is a PNG rebuilt from pixels, not the original bytes.
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_sending_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/long_text.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/png.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> _until(FutureOr<bool> Function() cond, {Duration timeout = const Duration(seconds: 40), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final antennad = findXd();

  test('a long text goes as a file; a sent image keeps its preview after the original is gone', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket);
    XDialog? bobSession;
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
          link: created.link, trust: 3, label: 'alice', connectTimeoutMs: 5000, password: bob.password)));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;
      await _until(() => m.contacts.isNotEmpty && m.subscribed, what: 'contact in the window');
      final link = m.contacts.single.linkId;
      await m.select(link);

      // 1. A crash report over the limit: the daemon's own code and words, then the file.
      final log = StringBuffer('Process:  Antenna [4127]\n');
      for (var i = 0; log.length < 70 * 1024; i++) {
        log.write('Thread $i Crashed:: Dispatch queue: com.apple.main-thread\n');
      }
      final text = log.toString();
      await m.send(text);
      final failed = m.chats[link]!.entries.last;
      print('LONG TEXT: ${failed.error} · ${failed.errorMessage}');
      expect(failed.error, XErrorCode.textTooLong);
      expect(failed.errorMessage, contains('${utf8Length(text)} bytes'));
      expect(failed.errorMessage, contains('65536'));
      expect(refusedAsTooLong(failed), isTrue);
      expect(await m.sendTextAsFile(link, text, failed: failed), TextFileResult.sent);
      expect(m.chats[link]!.entries.contains(failed), isFalse);
      await _until(() async => (await b.filesPending(all: true)).any((f) => f.name == 'Process-Antenna-4127.txt'),
          what: 'the file at the contact');
      final got = (await b.filesPending(all: true)).firstWhere((f) => f.name == 'Process-Antenna-4127.txt');
      expect(got.size, utf8Length(text));
      print('LONG TEXT: bob got ${got.name}, ${got.size} bytes, ${got.mime ?? got.senderMime}');

      // 2. A screenshot whose file is gone right after the send.
      final shot = File('${root.path}/Screenshot 2026-10-06 at 21.53.00.png')
        ..writeAsBytesSync(await pngWithText(2880, 1800, 'Comment', 'taken at Fifth Avenue'));
      await m.shareFile(link, shot.path);
      expect(m.outgoing, isEmpty, reason: '${m.outgoing.values.map((o) => o.error).toList()}');
      shot.deleteSync();
      final sent = m.files.values.firstWhere((f) => !f.incoming && f.name.startsWith('Screenshot'));
      expect(sent.mime, 'image/png', reason: 'the daemon read the signature');
      expect(m.hasSentPreview(sent), isTrue);
      final kept = (await m.sentPreviewBytes(sent))!;
      expect(kept.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(String.fromCharCodes(kept).contains('Fifth Avenue'), isFalse, reason: 'pixels only');
      expect(await pngSize(kept), (1600, 1000));
      print('PREVIEW: ${kept.length} bytes, 1600 x 1000, after the original was deleted');
    } on TimeoutException {
      print('ALICE LOG:\n${alice.log}\nBOB LOG:\n${bob.log}');
      rethrow;
    } finally {
      m.dispose();
      await bobSession?.cancel();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? 'no antennad: build it or set ANTENNAD_BIN' : false, timeout: const Timeout(Duration(minutes: 3)));
}
