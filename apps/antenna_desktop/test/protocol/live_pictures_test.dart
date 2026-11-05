// SPDX-License-Identifier: AGPL-3.0-only
// Profile pictures (x-control/7, CONTROL §28) against REAL daemons: Alex's Mac and Jordan's Mac at trust level 3. The
// window on A sets a drawn picture; B lists it for the contact, and B's window draws it. The window on A sets a photo
// from a PNG file it rendered (as the crop step does); B's `picture_photo` bytes are a JPEG that B's daemon made, not
// the file's bytes, and B's window draws exactly those bytes. Removing the picture on A is initials on B again.
// Run: ANTENNAD_BIN=<path to antennad> flutter test --tags live --concurrency=1 \
//   test/protocol/live_pictures_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/pictures.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 30), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<T> untilValue<T extends Object>(Future<T?> Function() get,
    {Duration timeout = const Duration(seconds: 30), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (true) {
    final v = await get();
    if (v != null) return v;
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// A 640 × 480 PNG drawn here: a gradient and a disc (no file from anywhere else).
Future<Uint8List> _png() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, 640, 480),
    Paint()
      ..shader = ui.Gradient.linear(
          Offset.zero, const Offset(640, 480), [const Color(0xFF3949AB), const Color(0xFFFF9800)]),
  );
  c.drawCircle(const Offset(320, 240), 100, Paint()..color = const Color(0xFFFFFFFF));
  final img = await rec.endRecording().toImage(640, 480);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  final antennad = findXd();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a picture set on one computer reaches the contact; a photo arrives rebuilt, never as the file', () async {
    final root = await tempRoot();
    final alex = XdNode('alex', root, antennad!);
    final jordan = XdNode('jordan', root, antennad);
    await Future.wait([alex.start(), jordan.start()]);
    final a = XControlClient(alex.socket);
    final b = XControlClient(jordan.socket);
    AppModel window(XdNode n) =>
        AppModel(connector: XControlClient.new, socketPath: n.socket, factsEvery: const Duration(seconds: 1));
    final ma = window(alex);
    final mb = window(jordan);
    try {
      await a.init(alex.password);
      await b.init(jordan.password);
      await openOwnerSession(a, alex.password);
      await openOwnerSession(b, jordan.password);
      // A daemon from before pictures: the test cannot run here (it runs once the daemon knows `pictures`)
      try {
        await a.pictures();
      } on XControlException catch (e) {
        if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest) {
          markTestSkipped('needs antennad with profile pictures (x-control/7, `pictures`): ${e.message}');
          return;
        }
        rethrow;
      }

      final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'Jordan', password: alex.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
        link: created.link,
        trust: 3,
        label: 'Alex',
        connectTimeoutMs: 5000,
        password: jordan.password,
      )));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;
      final linkOnB = (await b.contacts()).single.linkId;

      // Both windows, signed in and subscribed
      for (final (m, node) in [(ma, alex), (mb, jordan)]) {
        await m.connect();
        expect(await m.login(node.password), isNull);
        await until(() => m.subscribed, what: '${node.name}: subscription');
        expect(m.picturesSupported, isTrue);
      }

      // A drawn picture: set in A's window, listed on B for the contact, drawn by B's window from its own assets
      await ma.setPicture(drawn: 'set1/fox');
      expect(ma.pictureOfMine(), const DrawnPicture('set1/fox'));
      final drawnOnB = await untilValue(() async {
        for (final p in await b.pictures()) {
          if (p.linkId == linkOnB && p.agent == null && p.drawn != null) return p;
        }
        return null;
      }, what: 'B lists the drawn picture');
      expect(drawnOnB.drawn, 'set1/fox');
      expect(drawnOnB.contact, 'Alex');
      await until(() => mb.pictureOfContact(linkOnB) == const DrawnPicture('set1/fox'),
          what: "B's window: the picture event");
      print('DRAWN: ${drawnOnB.toJson()}');

      // A photo: the window renders a PNG into a file of its own and hands the daemon its path
      final dir = await Directory('${root.path}/staging').create();
      final file = File('${dir.path}/picture.png');
      final png = await _png();
      await file.writeAsBytes(png, flush: true);
      await ma.setPicture(photo: file.path);
      final own = ma.ownPictureEntry()!;
      expect(own.photo, isNotNull);
      expect(own.drawn, isNull);
      final ownBytes = (await a.picturePhoto(own.photo!)).data;
      expect(ownBytes.sublist(0, 3), [0xFF, 0xD8, 0xFF], reason: "A's own photo as its daemon rebuilt it: a JPEG");

      // B's window gets there by itself: the photo arrives unchecked (a `picture` event), the window asks `pictures`,
      // and B's daemon checks it then. Nothing here asks B's daemon first: up to preview.8 only such a call did, and
      // the window stayed on initials until the next unlock.
      await until(() => mb.pictureOfContact(linkOnB) is PhotoPicture,
          timeout: const Duration(seconds: 60), what: "B's window shows the photo by itself");
      final photoOnB = (await b.pictures())
          .singleWhere((p) => p.linkId == linkOnB && p.agent == null && p.photo != null && p.withheld == null);
      final got = await b.picturePhoto(photoOnB.photo!);
      expect(got.mime, 'image/jpeg');
      expect(got.data.sublist(0, 3), [0xFF, 0xD8, 0xFF], reason: 'a JPEG the daemon encoded');
      expect(got.data, isNot(png), reason: 'never the file the owner chose');
      expect(got.data.length, lessThanOrEqualTo(64 * 1024));
      // B's window draws exactly the bytes of B's daemon
      final shown = mb.pictureOfContact(linkOnB)! as PhotoPicture;
      expect(shown.id, photoOnB.photo);
      expect(shown.bytes, got.data);
      print('PHOTO: file ${png.length} bytes PNG → on B ${got.data.length} bytes JPEG (${photoOnB.photo})');

      // Removing it: initials on B again
      await ma.setPicture(remove: true);
      expect(ma.ownPictureEntry(), isNull);
      await until(() => mb.pictureOfContact(linkOnB) == null, what: 'B: back to initials');
    } finally {
      ma.dispose();
      mb.dispose();
      await Future.wait([alex.stop(), jordan.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 3)));
}
