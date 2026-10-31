// SPDX-License-Identifier: AGPL-3.0-only
// Files in the window against real antennad (x-control/3, CONTROL §14): a contact sends text, an image and EICAR;
// the window sees the quarantine stages as `file` events, takes the safe preview (the image is rebuilt by the daemon as
// PNG, not the original bytes), accepts a clean file into shared/, does not accept a threat without force and rejects
// it; the window sends a file to the contact, and a file with a secret only after approval with the owner password.
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_files_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// A [w] × [h] RGB PNG of noise: it does not compress, so the daemon's safe preview of it is well over one control
/// line (256 KiB), like the PNG of a screenshot or a detailed logo.
Uint8List noisyPng(int w, int h) {
  final raw = BytesBuilder(copy: false);
  var x = 0x2545F491;
  for (var y = 0; y < h; y++) {
    final row = Uint8List(1 + w * 3);
    for (var i = 1; i < row.length; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      row[i] = (x >> 16) & 0xff;
    }
    raw.add(row);
  }
  int crc(List<int> data) {
    var c = 0xffffffff;
    for (final b in data) {
      c ^= b;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
      }
    }
    return c ^ 0xffffffff;
  }

  final out = BytesBuilder(copy: false)..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(body)
      ..add((ByteData(4)..setUint32(0, crc(body))).buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2); // RGB
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', ZLibCodec(level: 6).encode(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

// The EICAR test string (harmless; antivirus engines and the daemon must treat it as a threat).
const _eicar = r'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*';

void main() {
  final antennad = findXd();
  final cli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final hasFiles = cli != null && File(cli).existsSync() && '${Process.runSync(cli, ['share', '--help']).stdout}'.isNotEmpty;

  test('files: quarantine stages, safe preview, accept/reject, send and the secret approve', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket, factsEvery: const Duration(seconds: 1));
    XDialog? bobSession;
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      bobSession = await openOwnerSession(b, bob.password);
      await m.connect();
      expect(await m.login(alice.password), isNull);
      expect(m.hello?.proto, controlProto); // the window speaks the latest version (files since x-control/3)
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

      // 1. Text from the contact: quarantine stages arrive as events, the preview is cleaned text, accepted into shared/.
      final report = File('${root.path}/report.txt')..writeAsStringSync('quarterly report\n' * 200);
      final sent = await b.shareFile('alice', report.path);
      expect(sent.state, 'sent');
      final seen = <String>{};
      await until(() {
        final f = m.files[sent.id];
        if (f != null) seen.add(f.state);
        return f?.state == 'checked';
      }, what: 'report checked in the window');
      final f1 = m.files[sent.id]!;
      print('REPORT: states seen ${seen.toList()}, verdict ${f1.verdict}, mime ${f1.mime}, sandbox ${f1.sandbox}');
      expect(f1.verdict, 'clean');
      expect(f1.messageId, isNotNull);
      expect(m.fileByMessage(f1.messageId!)?.id, f1.id, reason: 'the chat shows this message as a file card');
      final p1 = await m.previewFile(f1.id);
      expect(p1.preview?.kind, 'text');
      expect(p1.preview?.text, contains('quarterly report'));
      expect(await m.acceptFile(f1.id), isNull);
      expect(m.files[f1.id]!.state, 'accepted');
      expect(m.files[f1.id]!.dest, 'shared');
      final saved = File('${alice.dir}/links/bob/shared/${m.files[f1.id]!.savedAs}');
      expect(saved.readAsStringSync(), report.readAsStringSync());
      expect(saved.statSync().mode & 0x49, 0, reason: 'no exec bits');

      // 2. Image: the preview is a PNG the daemon built itself (not the original bytes).
      final pngSrc = File('test/goldens/assets/preview_page.png');
      final img = File('${root.path}/page.png')..writeAsBytesSync(pngSrc.readAsBytesSync());
      final sentImg = await b.shareFile('alice', img.path);
      await until(() => m.files[sentImg.id]?.state == 'checked', what: 'image checked');
      final p2 = await m.previewFile(sentImg.id);
      print('IMAGE: verdict ${m.files[sentImg.id]!.verdict}, preview ${p2.preview?.kind}, '
          '${p2.preview?.imagesPng.length} png, ${p2.preview?.imagesPng.firstOrNull?.length} bytes '
          '(original ${img.lengthSync()})');
      expect(p2.preview?.kind, 'image');
      expect(p2.preview!.imagesPng, isNotEmpty);
      expect(p2.preview!.imagesPng.first.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(p2.preview!.imagesPng.first, isNot(equals(img.readAsBytesSync())), reason: 'rebuilt from pixels');

      // 3. EICAR: a threat; not accepted without force; rejecting needs no password.
      final ev = File('${root.path}/notes.txt')..writeAsStringSync(_eicar);
      final sentEv = await b.shareFile('alice', ev.path);
      await until(() => m.files[sentEv.id]?.state == 'checked', what: 'eicar checked');
      final f3 = m.files[sentEv.id]!;
      print('EICAR: verdict ${f3.verdict}, findings ${f3.findings.map((x) => '${x.severity}:${x.code}').toList()}');
      expect(f3.verdict, 'threat');
      expect(f3.needsForce, isTrue);
      final err = await m.acceptFile(f3.id);
      expect(err, isA<XControlException>());
      expect((err! as XControlException).code, XErrorCode.forbidden);
      expect(await m.rejectFile(f3.id), isNull);
      expect(m.files[f3.id]!.state, 'rejected');

      // 4. The window sends a file to the contact; the contact accepts it.
      final out = File('${root.path}/plan.txt')..writeAsStringSync('plan: ship the beta\n');
      await m.shareFile(link, out.path);
      expect(m.outgoing, isEmpty, reason: '${m.outgoing.values.map((o) => o.error).toList()}');
      final mine = m.filesOfLink(link).firstWhere((f) => !f.incoming && f.name == 'plan.txt');
      expect(mine.state, 'sent');
      FileInfo? atBob;
      final sw = Stopwatch()..start();
      while (atBob?.state != 'checked') {
        if (sw.elapsed > const Duration(seconds: 40)) throw TimeoutException('plan.txt checked at bob');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        atBob = (await b.filesPending()).where((f) => f.name == 'plan.txt').firstOrNull;
      }
      expect((await b.fileAccept(atBob!.id)).state, 'accepted');
      await until(() => m.files[mine.id]?.state == 'accepted', what: 'the window sees the contact accepted it');

      // 5. A secret in the file being sent: the daemon will not send it without the owner's approval (password), then a retry.
      final key = File('${root.path}/keys-backup.txt')
        ..writeAsStringSync('-----BEGIN OPENSSH PRIVATE KEY-----\n'
            'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
            'QyNTUxOQAAACDZ0f9mZt7mG7a2nY0yQGgYQ0Kz1d4tJ7C9rN2Zr0bLwAAAAJgAAAAA\n'
            '-----END OPENSSH PRIVATE KEY-----\n');
      await m.shareFile(link, key.path);
      final o = m.outgoing.values.single;
      print('SECRET: approval ${o.approvalId}, error ${o.error}');
      expect(o.approvalId, isNotNull, reason: 'a private key is held for the owner approve');
      expect(await m.approve(o.approvalId!, alice.password), isNull);
      await m.shareFile(link, key.path, approvalId: o.approvalId, retry: o);
      expect(m.outgoing, isEmpty, reason: '${o.error}');
      expect(m.filesOfLink(link).any((f) => !f.incoming && f.name == 'keys-backup.txt'), isTrue);
    } on TimeoutException {
      print('ALICE LOG:\n${alice.log}\nBOB LOG:\n${bob.log}');
      rethrow;
    } finally {
      m.dispose();
      await bobSession?.cancel();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null || !hasFiles ? 'needs antennad with files (x-control/3)' : false, timeout: const Timeout(Duration(minutes: 3)));

  // The maintainer's own setup: an agent on the owner's server (∞, level 5) sends a picture to the Mac. The daemon
  // accepts it at once (D-99), so the window first sees it accepted, and the picture in the conversation comes from
  // the safe preview of an accepted file, over one long reply line. Up to preview.8 both failed on every computer:
  // the accept deleted the preview (`file_preview` answered `bad_state`), and the window refused any reply line over
  // 256 KiB; every such picture showed "Couldn't show the preview image".
  test('a picture from an own computer: accepted at once, its safe preview still shown, longer than a line', () async {
    final root = await tempRoot();
    final mac = XdNode('mac', root, antennad!);
    final server = XdNode('server', root, antennad);
    await Future.wait([mac.start(), server.start()]);
    final a = XControlClient(mac.socket);
    final b = XControlClient(server.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: mac.socket, factsEvery: const Duration(seconds: 1));
    XDialog? serverSession;
    try {
      await a.init(mac.password);
      await b.init(server.password);
      serverSession = await openOwnerSession(b, server.password);
      await m.connect();
      expect(await m.login(mac.password), isNull);
      a.sessionToken = m.daemon.sessionToken;
      final inv = Events(a.open(InviteRequest(trust: 5, ttlSecs: 120, label: 'server', password: mac.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
        link: created.link,
        trust: 5,
        label: 'mac',
        connectTimeoutMs: 5000,
        password: server.password,
      )));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;
      await until(() => m.contacts.isNotEmpty && m.subscribed, what: 'contact in the window');

      final logo = File('${root.path}/volna-logo-1024.png')..writeAsBytesSync(noisyPng(640, 480));
      final sent = await b.shareFile('mac', logo.path);
      await until(() => m.files[sent.id]?.state == 'accepted',
          timeout: const Duration(seconds: 60), what: 'accepted by the daemon at level 5');
      final f = m.files[sent.id]!;
      expect((f.verdict, f.mime, f.dest), ('clean', 'image/png', 'shared'));
      expect(m.localFileOf(f), isNotNull, reason: 'Open and Show in Finder have the saved file');
      final p = await m.previewFile(f.id);
      expect(p.file.state, 'accepted');
      expect(p.preview?.kind, 'image');
      final png = p.preview!.imagesPng.single;
      print('LEVEL 5 PICTURE: original ${logo.lengthSync()} bytes, preview ${png.length} bytes PNG '
          '(${base64.encode(png).length} base64 characters in one reply line)');
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(base64.encode(png).length, greaterThan(maxLine), reason: 'the reply is longer than a request may be');
      expect(png, isNot(equals(logo.readAsBytesSync())), reason: 'rebuilt from pixels, never the original');
    } on TimeoutException {
      print('MAC LOG:\n${mac.log}\nSERVER LOG:\n${server.log}');
      rethrow;
    } finally {
      m.dispose();
      await serverSession?.cancel();
      await Future.wait([mac.stop(), server.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null || !hasFiles ? 'needs antennad with files (x-control/3)' : false, timeout: const Timeout(Duration(minutes: 3)));
}
