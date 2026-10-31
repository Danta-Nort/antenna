// SPDX-License-Identifier: AGPL-3.0-only
// Profile pictures in the window (x-control/7, CONTROL §28), on the fake daemon:
// - the protocol shapes: `pictures`, `picture_set` with exactly one of drawn/photo/remove, `picture_photo`, the event;
// - the picker: a tab per set, the grid, the current one marked, a click applies at once, Remove, the photo flow (a
//   512 × 512 PNG of the visible square from the staging folder, deleted once the daemon answered);
// - every place a picture shows: the chat list, the header, the group chat (never on my own messages), the contact
//   card, the Agents page, My devices; a contact's agent keeps the agent badge;
// - what is never drawn: an id the window does not know, a withheld photo, a photo before the daemon's rebuilt bytes,
//   and never the bytes of the file the owner chose;
// - an older daemon: no picture actions, everybody as before;
// - every bundled picture decodes at its size (WebP in `flutter test` on Linux).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/pictures.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/pictures/picture_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_devices.dart';
import '../support/fake_pictures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance(initial: ThemeChoice.light)));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Finder _key(String k) => find.byKey(Key(k));
Finder _within(Finder of, Finder f) => find.descendant(of: of, matching: f);

/// The bytes a `PictureFace` photo is drawn from.
Uint8List _photoBytesIn(WidgetTester t, Finder of) {
  final img = t.widget<Image>(_within(of, find.byType(Image)).first);
  return (img.image as MemoryImage).bytes;
}

/// Jordan's link with his agents and mine (`teamHistory`), Emily, Ryan; pictures for most of them.
FakeDaemon _daemon({List<PictureEntry> Function(FakeDaemon d)? pictures}) {
  final d = FakeDaemon(
    contacts: [jordanTeam, emily, ryan],
    history: {...demoHistory(), jordanTeam.linkId: teamHistory()},
  )..agentList = [
      const AgentInfo(name: 'builder', createdMs: 0, localLevel: 5, everyone: false),
      const AgentInfo(name: 'chatgpt', createdMs: 0, localLevel: 3, everyone: false),
    ];
  d.pictureList = pictures?.call(d) ??
      [
        const PictureEntry(drawn: 'set1/fox'),
        const PictureEntry(agent: 'builder', drawn: 'set2/wolf'),
        PictureEntry(contact: emily.label, linkId: emily.linkId, drawn: 'set1/rabbit'),
        PictureEntry(contact: jordanTeam.label, linkId: jordanTeam.linkId, photo: d.addPhoto(fakeRebuiltJpeg)),
        PictureEntry(
            contact: jordanTeam.label, linkId: jordanTeam.linkId, agent: 'claude-backend', drawn: 'set3/axolotl'),
      ];
  return d;
}

/// A 900 × 600 PNG drawn here (no file from anywhere else): a gradient with a mark in the middle.
Future<Uint8List> _makePng() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, 900, 600),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(900, 600), [Colors.indigo, Colors.orange]),
  );
  c.drawCircle(const Offset(450, 300), 120, Paint()..color = Colors.white);
  final img = await rec.endRecording().toImage(900, 600);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

/// PNG width and height from the IHDR chunk.
(int, int) _pngSize(Uint8List b) {
  expect(b.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], reason: 'a PNG');
  final v = ByteData.sublistView(b);
  return (v.getUint32(16), v.getUint32(20));
}

class _FakeChooser implements PhotoChooser {
  _FakeChooser(this.path);
  final String? path;
  final asked = <(String, String)>[];

  @override
  Future<String?> pick({required String label, required String confirm}) async {
    asked.add((label, confirm));
    return path;
  }
}

Future<void> _openSettings(WidgetTester t) async {
  await t.tap(_key('nav-settings'));
  await _settle(t);
}

/// Wait outside FakeAsync until [done] (image decoding and encoding run in the engine).
Future<void> _until(WidgetTester t, bool Function() done) async {
  await t.runAsync(() async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await t.pump();
    }
  });
  expect(done(), isTrue);
}

void main() {
  group('protocol', () {
    test('the requests carry exactly what the daemon parses', () {
      expect(const PicturesRequest().toJson(), {'cmd': 'pictures'});
      expect(const PictureSetRequest(drawn: 'set1/fox').toJson(), {'cmd': 'picture_set', 'drawn': 'set1/fox'});
      expect(const PictureSetRequest(agent: 'lead', photo: '/tmp/a.png').toJson(),
          {'cmd': 'picture_set', 'agent': 'lead', 'photo': '/tmp/a.png'});
      expect(const PictureSetRequest(remove: true).toJson(), {'cmd': 'picture_set', 'remove': true});
      expect(const PicturePhotoRequest('0123456789abcdef').toJson(),
          {'cmd': 'picture_photo', 'id': '0123456789abcdef'});
    });

    test('the replies and the event parse; the photo is the bytes of its base64', () {
      final r = Reply.fromJson({
        'type': 'pictures',
        'pictures': [
          {'drawn': 'set1/fox', 'updated_ms': 5},
          {'contact': 'bob', 'link_id': 'ab' * 32, 'agent': 'lead', 'photo': '0123456789abcdef', 'updated_ms': 6},
          {'contact': 'eve', 'link_id': 'cd' * 32, 'withheld': 'level', 'updated_ms': 7, 'frame': 'gold'},
        ],
      }) as PicturesReply;
      expect(r.pictures, hasLength(3));
      expect(r.pictures[0].own, isTrue);
      expect(r.pictures[0].drawn, 'set1/fox');
      expect(r.pictures[1].own, isFalse);
      expect(r.pictures[1].agent, 'lead');
      expect(r.pictures[1].photo, '0123456789abcdef');
      expect(r.pictures[2].withheld, PictureWithheld.level);
      final p = Reply.fromJson({'type': 'picture_photo', 'id': 'aa', 'mime': 'image/jpeg', 'data_base64': '/9j/2Q=='})
          as PicturePhotoReply;
      expect(p.data, base64.decode('/9j/2Q=='));
      expect(() => Reply.fromJson({'type': 'picture_photo', 'id': 'aa', 'data_base64': '%%'}),
          throwsA(isA<XProtocolException>()));
      final e = XEvent.fromJson(
          {'kind': 'picture', 'contact': 'bob', 'link_id': 'ab', 'drawn': 'set2/wolf', 'updated_ms': 9});
      expect((e as PictureEvent).entry.drawn, 'set2/wolf');
      expect(e.entry.linkId, 'ab');
    });
  });

  testWidgets('the picker: a tab per set, the grid, the current one marked; a click applies at once; Remove',
      (t) async {
    final d = _daemon();
    final m = await _model(d);
    await _app(t, m);
    await _openSettings(t);
    // Profile is the first section and opens by default: the owner's picture and what it is
    expect(_key('profile-card'), findsOneWidget);
    expect(_within(_key('profile-picture'), _key('picture-drawn-set1/fox')), findsOneWidget);
    expect(_within(_key('profile-card'), find.text(en.pictureCurrentDrawn('Fox', 'Soft'))), findsOneWidget);

    await t.tap(_key('profile-picture-change'));
    await _settle(t);
    expect(find.text(en.profilePicture), findsWidgets);
    for (final s in ['set1', 'set2', 'set3']) {
      expect(_key('picture-set-$s'), findsOneWidget);
    }
    expect(_within(_key('picture-set-set2'), find.text('Modern')), findsOneWidget);
    // The covers are the tabs' icons
    expect(_within(_key('picture-set-set3'), find.byType(Image)), findsOneWidget);
    // The set of the current picture, its 19 animals, the fox marked
    expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('picture-cell-set1/')), findsNWidgets(19));
    expect(_key('picture-current-set1/fox'), findsOneWidget);
    expect(find.byTooltip('Capybara'), findsOneWidget);

    await t.tap(_key('picture-set-set2'));
    await _settle(t);
    expect(_key('picture-cell-set2/wolf'), findsOneWidget);
    expect(_key('picture-cell-set1/fox'), findsNothing);
    await t.tap(_key('picture-cell-set2/wolf'));
    await _settle(t);
    expect(d.pictureSetCalls.single.drawn, 'set2/wolf');
    expect(d.pictureSetCalls.single.agent, isNull, reason: 'the owner\'s own picture');
    expect(_key('picture-current-set2/wolf'), findsOneWidget, reason: 'marked at once');
    expect(_within(_key('picture-current'), _key('picture-drawn-set2/wolf')), findsOneWidget);

    await t.tap(_key('picture-remove'));
    await _settle(t);
    expect(d.pictureSetCalls.last.remove, isTrue);
    expect(_key('picture-remove'), findsNothing, reason: 'nothing left to remove');
    expect(_key('picture-current-set2/wolf'), findsNothing);
    await t.tap(_key('picture-done'));
    await _settle(t);
    expect(_within(_key('profile-card'), find.text(en.profilePictureNone)), findsOneWidget);
    expect(_within(_key('profile-card'), _key('picture-none')), findsOneWidget);
    expect(_key('profile-picture-remove'), findsNothing);
  });

  testWidgets('errors are said in words by code', (t) async {
    final d = _daemon();
    final m = await _model(d);
    await _app(t, m);
    await _openSettings(t);
    await t.tap(_key('profile-picture-change'));
    await _settle(t);
    d.pictureSetError = const XControlException(XErrorCode.badRequest, 'bad picture id');
    await t.tap(_key('picture-cell-set1/owl'));
    await _settle(t);
    expect(_within(_key('picture-error'), find.text(en.pictureErrBad)), findsOneWidget);
    expect(_key('picture-current-set1/fox'), findsOneWidget, reason: 'the old one stays');
    expect(describePictureError(en, const XControlException(XErrorCode.pictureRefused, '')), en.pictureErrRefused);
    expect(describePictureError(en, const XControlException(XErrorCode.sandboxUnavailable, '')), en.pictureErrSandbox);
    expect(describePictureError(en, const XControlException(XErrorCode.notFound, '')), en.pictureErrNotFound);
  });

  testWidgets('my photo: the visible square as a 512 px PNG from the staging folder, deleted after the reply; the '
      'picture shown is the daemon\'s rebuilt photo, never the file', (t) async {
    final tmp = Directory.systemTemp.createTempSync('pictures_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final staging = OutgoingStaging.instance;
    OutgoingStaging.instance = OutgoingStaging('${tmp.path}/outgoing');
    addTearDown(() => OutgoingStaging.instance = staging);
    final src = File('${tmp.path}/holiday.png');
    await t.runAsync(() async => src.writeAsBytesSync(await _makePng()));
    final chooser = _FakeChooser(src.path);
    final old = PhotoChooser.instance;
    PhotoChooser.instance = chooser;
    addTearDown(() => PhotoChooser.instance = old);

    final d = _daemon();
    final rebuilt = Uint8List.fromList(fakeRebuiltJpeg);
    d.rebuildPhoto = (_) => rebuilt;
    final m = await _model(d);
    await _app(t, m);
    await _openSettings(t);
    await t.tap(_key('profile-picture-change'));
    await _settle(t);
    await t.runAsync(() async => t.tap(_key('picture-photo')));
    await _until(t, () => _key('picture-crop-viewport').evaluate().isNotEmpty);
    expect(chooser.asked.single, (en.pictureImages, en.pictureChoose));
    expect(find.text(en.pictureCropHint), findsOneWidget);
    expect(_key('picture-crop-zoom'), findsOneWidget);

    await t.runAsync(() async => t.tap(_key('picture-crop-use')));
    await _until(t, () => d.pictureSetCalls.isNotEmpty && _key('picture-crop-viewport').evaluate().isEmpty);
    final sent = d.pictureSetCalls.single;
    expect(sent.photo, isNotNull);
    expect(sent.drawn, isNull);
    expect(OutgoingStaging.instance!.owns(sent.photo!), isTrue, reason: 'a copy in the window\'s staging folder');
    expect(sent.photo, isNot(src.path), reason: 'never the original file');
    final staged = d.photoFilesRead[sent.photo]!;
    expect(_pngSize(staged), (512, 512));
    expect(File(sent.photo!).existsSync(), isFalse, reason: 'deleted once the daemon answered');
    expect(Directory(File(sent.photo!).parent.path).existsSync(), isFalse);
    // The current picture: the daemon's rebuilt photo, fetched by id
    await _settle(t);
    final id = d.pictureList.firstWhere((p) => p.own && p.agent == null).photo!;
    expect(d.picturePhotoCalls, contains(id));
    final shown = _photoBytesIn(t, _key('picture-current'));
    expect(shown, rebuilt);
    expect(shown, isNot(staged));
    expect(shown, isNot(src.readAsBytesSync()));
    expect(_within(_key('picture-current'), _key('picture-photo-$id')), findsOneWidget);
  });

  testWidgets('a photo the daemon refuses: said in words, and the staged file is still deleted', (t) async {
    final tmp = Directory.systemTemp.createTempSync('pictures_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final staging = OutgoingStaging.instance;
    OutgoingStaging.instance = OutgoingStaging('${tmp.path}/outgoing');
    addTearDown(() => OutgoingStaging.instance = staging);
    final src = File('${tmp.path}/scan.png');
    await t.runAsync(() async => src.writeAsBytesSync(await _makePng()));
    final old = PhotoChooser.instance;
    PhotoChooser.instance = _FakeChooser(src.path);
    addTearDown(() => PhotoChooser.instance = old);
    final d = _daemon()..pictureSetError = const XControlException(XErrorCode.pictureRefused, 'check_failed');
    final m = await _model(d);
    await _app(t, m);
    await _openSettings(t);
    await t.tap(_key('profile-picture-change'));
    await _settle(t);
    await t.runAsync(() async => t.tap(_key('picture-photo')));
    await _until(t, () => _key('picture-crop-viewport').evaluate().isNotEmpty);
    await t.runAsync(() async => t.tap(_key('picture-crop-use')));
    await _until(t, () => _key('picture-error').evaluate().isNotEmpty);
    expect(find.text(en.pictureErrRefused), findsOneWidget);
    expect(_key('picture-crop-viewport'), findsOneWidget, reason: 'the owner can try again or go back');
    expect(Directory('${tmp.path}/outgoing').listSync(), isEmpty, reason: 'nothing left in the staging folder');
  });

  testWidgets('a file the window cannot open is said in words; nothing is sent', (t) async {
    final tmp = Directory.systemTemp.createTempSync('pictures_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final src = File('${tmp.path}/notes.heic')..writeAsStringSync('not an image');
    final old = PhotoChooser.instance;
    PhotoChooser.instance = _FakeChooser(src.path);
    addTearDown(() => PhotoChooser.instance = old);
    final d = _daemon();
    final m = await _model(d);
    await _app(t, m);
    await _openSettings(t);
    await t.tap(_key('profile-picture-change'));
    await _settle(t);
    await t.runAsync(() async => t.tap(_key('picture-photo')));
    await _until(t, () => _key('picture-error').evaluate().isNotEmpty);
    expect(find.text(en.pictureErrOpen), findsOneWidget);
    expect(d.pictureSetCalls, isEmpty);
  });

  testWidgets('every place: the list, the header, the group chat (none on my own messages), the card, Agents',
      (t) async {
    final d = _daemon();
    final m = await _model(d);
    await m.select(jordanTeam.linkId, chat: const ThreadKey.agent('claude-backend'));
    await _app(t, m);
    final jordanPhoto = d.pictureList.firstWhere((p) => p.linkId == jordanTeam.linkId && p.agent == null).photo!;

    // The chat list: Jordan's photo, Emily's rabbit, Ryan's initials; Jordan's agent with its picture and the badge
    expect(_within(_key('contact-${jordanTeam.label}'), _key('picture-photo-$jordanPhoto')), findsOneWidget);
    expect(_photoBytesIn(t, _key('contact-${jordanTeam.label}')), d.photoMap[jordanPhoto]);
    expect(_within(_key('contact-${emily.label}'), _key('picture-drawn-set1/rabbit')), findsOneWidget);
    expect(_within(_key('contact-${ryan.label}'), find.byType(Image)), findsNothing);
    expect(_within(_key('contact-${ryan.label}'), find.text('RB')), findsOneWidget);
    final row = _key('chat-${jordanTeam.label}-agent-claude-backend');
    expect(_within(row, _key('picture-drawn-set3/axolotl')), findsOneWidget);
    expect(_within(row, _key('agent-picture-badge')), findsOneWidget, reason: 'a contact\'s agent keeps the badge');
    expect(_within(row, _key('agent-mark-generic')), findsNothing);
    // design-bot has no picture: the monogram as before
    expect(_within(_key('chat-${jordanTeam.label}-agent-design-bot'), _key('agent-mark-generic')), findsOneWidget);

    // The header of the open chat
    expect(_within(_key('chat-header-avatar'), _key('picture-drawn-set3/axolotl')), findsOneWidget);
    expect(_within(_key('chat-header-avatar'), _key('agent-picture-badge')), findsOneWidget);

    // The group chat: the contact's agent and my agent have their pictures; my own message has none, though I have
    // one. The whole thread, not the default "With me" filter (D-UI-44).
    await t.tap(_key('thread-filter-all'));
    await _settle(t);
    final history = teamHistory();
    String id(int seq) => history.firstWhere((x) => x.seq == seq).id;
    expect(_within(_key('avatar-${id(53)}'), _key('picture-drawn-set3/axolotl')), findsOneWidget);
    expect(_within(_key('avatar-${id(53)}'), _key('agent-picture-badge')), findsOneWidget);
    expect(_within(_key('avatar-${id(52)}'), _key('picture-drawn-set2/wolf')), findsOneWidget, reason: 'builder: mine');
    expect(_within(_key('avatar-${id(54)}'), _key('agent-mark-generic')), findsOneWidget,
        reason: 'chatgpt: no picture');
    expect(_key('avatar-${id(56)}'), findsNothing, reason: 'my own message carries no picture');
    expect(_key('picture-drawn-set1/fox'), findsNothing, reason: 'my own picture is nowhere in my conversations');

    // The contact card: the person and its agents
    await m.select(jordanTeam.linkId);
    await _settle(t);
    await t.tap(_key('card-toggle'));
    await _settle(t);
    expect(_within(find.byType(Scrollable).last, _key('picture-photo-$jordanPhoto')), findsWidgets);
    await t.scrollUntilVisible(_key('peer-agent-claude-backend'), 300, scrollable: find.byType(Scrollable).last);
    expect(_within(_key('peer-agent-claude-backend'), _key('picture-drawn-set3/axolotl')), findsOneWidget);
    expect(_within(_key('peer-agent-claude-backend'), _key('agent-picture-badge')), findsOneWidget);
    expect(_within(_key('peer-agent-design-bot'), find.byType(Image)), findsNothing);

    // Agents: my agent with its picture and Picture…, which sets that agent's
    await t.tap(_key('agents-button'));
    await _settle(t);
    await _settle(t);
    expect(_within(_key('agent-row-builder'), _key('picture-drawn-set2/wolf')), findsOneWidget);
    expect(_within(_key('agent-row-chatgpt'), find.byType(Image)), findsNothing);
    await t.tap(_key('agent-picture-chatgpt'));
    await _settle(t);
    expect(find.text(en.pictureTitleAgent('chatgpt')), findsOneWidget);
    await t.tap(_key('picture-set-set3'));
    await _settle(t);
    await t.tap(_key('picture-cell-set3/robot'));
    await _settle(t);
    expect(d.pictureSetCalls.single.agent, 'chatgpt');
    expect(d.pictureSetCalls.single.drawn, 'set3/robot');
    await t.tap(_key('picture-done'));
    await _settle(t);
    expect(_within(_key('agent-row-chatgpt'), _key('picture-drawn-set3/robot')), findsOneWidget);
    await t.scrollUntilVisible(_key('contact-agent-${jordanTeam.label}-claude-backend'), 300,
        scrollable: find.byType(Scrollable).last);
    expect(_within(_key('contact-agent-${jordanTeam.label}-claude-backend'), _key('picture-drawn-set3/axolotl')),
        findsOneWidget);
  });

  testWidgets('My devices: an own computer shows the picture chosen there, its agents theirs', (t) async {
    const mini = 'Mac mini';
    final link = 'aa' * 32;
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
      ..devicesEnabled = true
      ..pictureList = [
        PictureEntry(contact: mini, linkId: link, drawn: 'set3/robot'),
        PictureEntry(contact: mini, linkId: link, agent: 'codex', drawn: 'set2/raven'),
      ];
    final m = await _model(d);
    d.devicesState = demoDevices();
    await m.refreshDevices();
    t.view.physicalSize = const Size(1440, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await _settle(t);
    await t.tap(_key('nav-devices'));
    await _settle(t);
    expect(_within(_key('device-$mini'), _key('picture-drawn-set3/robot')), findsWidgets);
    expect(_within(_key('device-agent-$mini-codex'), _key('picture-drawn-set2/raven')), findsOneWidget);
    expect(_within(_key('device-agent-$mini-codex'), _key('agent-picture-badge')), findsOneWidget);
    expect(_within(_key('device-request-k2ab9c1d'), _key('picture-drawn-set2/raven')), findsOneWidget,
        reason: 'a request of that computer\'s agent');
    expect(_within(_key('device-agent-$mini-helper'), find.byType(Image)), findsNothing);
  });

  testWidgets('never drawn: an unknown id, a withheld photo, a photo before its rebuilt bytes; events apply',
      (t) async {
    late String withheldPhoto;
    final d = _daemon(pictures: (d) {
      withheldPhoto = d.addPhoto(fakeRebuiltJpeg);
      return [
        PictureEntry(contact: emily.label, linkId: emily.linkId, drawn: 'set9/unicorn'),
        PictureEntry(contact: ryan.label, linkId: ryan.linkId, photo: withheldPhoto, withheld: PictureWithheld.refused),
        PictureEntry(contact: jordanTeam.label, linkId: jordanTeam.linkId, photo: 'ffffffffffffffff'),
        PictureEntry(contact: jordanTeam.label, linkId: jordanTeam.linkId, agent: 'claude-backend', drawn: '../../x'),
      ];
    });
    final m = await _model(d);
    await _app(t, m);
    expect(_within(_key('contact-${emily.label}'), find.byType(Image)), findsNothing, reason: 'an unknown id');
    expect(_within(_key('contact-${emily.label}'), find.text('EC')), findsOneWidget);
    expect(_within(_key('contact-${ryan.label}'), find.byType(Image)), findsNothing, reason: 'withheld');
    expect(d.picturePhotoCalls, isNot(contains(withheldPhoto)), reason: 'a withheld photo is not even fetched');
    expect(d.picturePhotoCalls, contains('ffffffffffffffff'));
    expect(_within(_key('contact-${jordanTeam.label}'), find.byType(Image)), findsNothing,
        reason: 'no rebuilt bytes (the daemon had none): initials');
    expect(_within(_key('chat-${jordanTeam.label}-agent-claude-backend'), _key('agent-mark-generic')), findsOneWidget);

    // A `picture` event: Emily chose a known picture; then removed it
    m.handleEvent(PictureEvent(PictureEntry(contact: emily.label, linkId: emily.linkId, drawn: 'set2/eagle')));
    await _settle(t);
    expect(_within(_key('contact-${emily.label}'), _key('picture-drawn-set2/eagle')), findsOneWidget);
    m.handleEvent(PictureEvent(PictureEntry(contact: emily.label, linkId: emily.linkId)));
    await _settle(t);
    expect(_within(_key('contact-${emily.label}'), find.byType(Image)), findsNothing);
    expect(_within(_key('contact-${emily.label}'), find.text('EC')), findsOneWidget);
    // A contact's photo that has just arrived is unchecked: the daemon checks it on the next `pictures`, so the window
    // asks at once and draws the photo it gets (up to preview.8 it waited for the next unlock: initials meanwhile).
    final photo = d.addPhoto(fakeRebuiltJpeg);
    final before = d.calls.where((c) => c == 'pictures').length;
    d.pictureList = [
      ...d.pictureList,
      PictureEntry(contact: emily.label, linkId: emily.linkId, agent: 'claude-volna', photo: photo),
    ];
    m.handleEvent(PictureEvent(PictureEntry(
        contact: emily.label, linkId: emily.linkId, agent: 'claude-volna', withheld: PictureWithheld.unavailable)));
    await _settle(t);
    expect(d.calls.where((c) => c == 'pictures').length, before + 1, reason: 'the list is asked so the photo is checked');
    expect(m.pictureOfContact(emily.linkId, agent: 'claude-volna'), PhotoPicture(photo, fakeRebuiltJpeg));
    // A drawn picture or a checked photo needs no check: nothing more is asked.
    m.handleEvent(PictureEvent(PictureEntry(contact: emily.label, linkId: emily.linkId, drawn: 'set2/eagle')));
    await _settle(t);
    expect(d.calls.where((c) => c == 'pictures').length, before + 1);
    // `lagged`: the list is asked again
    final asked = d.calls.where((c) => c == 'pictures').length;
    m.handleEvent(const Lagged(3));
    await _settle(t);
    expect(d.calls.where((c) => c == 'pictures').length, asked + 1);
  });

  testWidgets('the contact card says why a photo is withheld, never for an agent with no picture at all', (t) async {
    final d = _daemon(pictures: (d) {
      final withheldPhoto = d.addPhoto(fakeRebuiltJpeg);
      return [
        PictureEntry(contact: jordanTeam.label, linkId: jordanTeam.linkId, agent: 'claude-backend', drawn: 'set3/axolotl'),
        PictureEntry(
            contact: jordanTeam.label,
            linkId: jordanTeam.linkId,
            agent: 'design-bot',
            photo: withheldPhoto,
            withheld: PictureWithheld.unavailable),
      ];
    });
    final m = await _model(d);
    await m.select(jordanTeam.linkId);
    await _app(t, m);
    await t.tap(_key('card-toggle'));
    await _settle(t);
    await t.scrollUntilVisible(_key('peer-agent-design-bot'), 300, scrollable: find.byType(Scrollable).last);
    expect(_within(_key('peer-agent-design-bot'), find.text(en.pictureWithheldUnavailable)), findsOneWidget,
        reason: 'a photo that could not be checked says so, instead of looking like no picture was set');
    expect(_within(_key('peer-agent-claude-backend'), find.text(en.pictureWithheldUnavailable)), findsNothing,
        reason: 'negative control: a picture that shows fine carries no note');
  });

  group('an older daemon', () {
    testWidgets('a v7 daemon without pictures: no actions, the line says why, everybody as before', (t) async {
      final d = _daemon()..picturesEnabled = false;
      final m = await _model(d);
      await m.select(jordanTeam.linkId);
      await _app(t, m);
      expect(m.picturesSupported, isFalse);
      expect(find.byKey(const Key('agent-picture-badge')), findsNothing);
      expect(_within(_key('contact-${emily.label}'), find.byType(Image)), findsNothing);
      await _openSettings(t);
      expect(_within(_key('profile-card'), find.text(en.pictureNeedNewer)), findsOneWidget);
      expect(t.widget<OutlinedButton>(_key('profile-picture-change')).onPressed, isNull);
      await t.tap(_key('agents-button'));
      await _settle(t);
      await _settle(t);
      expect(_key('agent-row-builder'), findsOneWidget);
      expect(_key('agent-picture-builder'), findsNothing);
      // Asked once; not again on `lagged`
      final asked = d.calls.where((c) => c == 'pictures').length;
      expect(asked, 1);
      m.handleEvent(const Lagged(1));
      await _settle(t);
      expect(d.calls.where((c) => c == 'pictures').length, asked);
    });

    testWidgets('a v6 daemon is never asked', (t) async {
      final d = _daemon()..protoVersion = 6;
      final m = await _model(d);
      await _app(t, m);
      expect(d.calls, isNot(contains('pictures')));
      expect(m.picturesSupported, isFalse);
    });

    testWidgets('the picker itself says it on an older daemon', (t) async {
      final d = _daemon()..picturesEnabled = false;
      final m = await _model(d);
      await _app(t, m);
      unawaited(showPicturePicker(t.element(find.byType(Scaffold).first)));
      await _settle(t);
      expect(_key('picture-need-newer'), findsOneWidget);
      expect(t.widget<OutlinedButton>(_key('picture-photo')).onPressed, isNull);
      await t.tap(_key('picture-cell-set1/owl'));
      await _settle(t);
      expect(d.pictureSetCalls, isEmpty);
    });
  });

  testWidgets('every bundled picture and cover decodes at its size', (t) async {
    // The files as the bundle has them (pubspec.yaml lists the folders); read directly, since the test asset channel
    // does not answer inside runAsync
    final catalog = PictureCatalog.fromJson(jsonDecode(File(PictureCatalog.manifest).readAsStringSync()));
    expect(catalog.sets.map((s) => s.id), ['set1', 'set2', 'set3']);
    expect(catalog.sets.fold<int>(0, (n, s) => n + s.animals.length), 55);
    expect(catalog.knows('set3/snow-leopard'), isTrue);
    expect(catalog.knows('set1/unicorn'), isFalse);
    expect(catalog.knows('set1/../set2/wolf'), isFalse);
    final files = <String, int>{
      for (final s in catalog.sets) ...{
        for (final a in s.animals) ...{
          const DrawnPicture('x').assetFor(64).replaceFirst('x', '${s.id}/${a.id}'): 128,
          const DrawnPicture('x').assetFor(65).replaceFirst('x', '${s.id}/${a.id}'): 512,
        },
        if (s.coverAsset != null) s.coverAsset!: 128,
      },
    };
    expect(files, hasLength(55 * 2 + 3));
    await t.runAsync(() async {
      for (final MapEntry(key: asset, value: side) in files.entries) {
        final codec = await ui.instantiateImageCodec(File(asset).readAsBytesSync());
        final frame = await codec.getNextFrame();
        expect((frame.image.width, frame.image.height), (side, side), reason: asset);
        frame.image.dispose();
        codec.dispose();
      }
    });
  });
}
