// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for profile pictures (x-control/7, CONTROL §28): the picker (the owner's picture, the fox of the first set
// current), Jordan's group chat where everybody but the owner's own messages has a picture (Emily and the agents drawn,
// Jordan a photo the daemon rebuilt, Ryan without one, Rachel's photo withheld at level 1), Settings → Profile, and the
// crop step of the owner's own photo.

part of 'scenarios.dart';

/// The daemon's rebuilt photo of Jordan (a synthetic landscape: no person in the demo data).
Uint8List _jordanPhoto() => File('test/goldens/assets/photo_square.jpg').readAsBytesSync();

/// A photo file the owner chooses (1200 × 800, wider than the square).
const _ownPhotoFile = 'test/goldens/assets/photo_wide.jpg';

FakeDaemon _picturesDaemon() {
  final d = _team();
  final photo = d.addPhoto(_jordanPhoto());
  PictureEntry theirs(ContactInfo c, {String? agent, String? drawn, String? photo, String? withheld}) =>
      PictureEntry(contact: c.label, linkId: c.linkId, agent: agent, drawn: drawn, photo: photo, withheld: withheld);
  d.pictureList = [
    const PictureEntry(drawn: 'set1/fox'),
    const PictureEntry(agent: 'builder', drawn: 'set2/wolf'),
    const PictureEntry(agent: 'chatgpt', drawn: 'set3/robot'),
    theirs(emily, drawn: 'set1/rabbit'),
    theirs(jordanTeam, photo: photo),
    theirs(jordanTeam, agent: 'claude-backend', drawn: 'set3/axolotl'),
    theirs(jordanTeam, agent: 'design-bot', drawn: 'set3/chameleon'),
    theirs(buildBot, drawn: 'set2/eagle'),
    theirs(rachel, withheld: PictureWithheld.level),
  ];
  return d;
}

Future<AppModel> _picturesModel() async {
  final m = await _model(_picturesDaemon());
  await m.select(jordanTeam.linkId);
  return m;
}

/// The picker over Settings → Profile; [set] opens another set's tab.
Future<void> _openPicker(WidgetTester t, {String? set}) async {
  await t.tap(find.byKey(const Key('nav-settings')));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('profile-picture-change')));
  await t.pump(const Duration(milliseconds: 400));
  if (set != null) {
    await t.tap(find.byKey(Key('picture-set-$set')));
    await t.pump(const Duration(milliseconds: 400));
  }
  await _decodeImages(t);
}

/// The owner chose [_ownPhotoFile]: the crop step, decoded outside FakeAsync.
class _GoldenPhotoChooser implements PhotoChooser {
  @override
  Future<String?> pick({required String label, required String confirm}) async => File(_ownPhotoFile).absolute.path;
}

void _definePictureScenarios() {
  _s('78_picture_picker', (t) async {
    const name = '78_picture_picker';
    final m = await _picturesModel();
    await _frame(t, XApp(model: m));
    await _openPicker(t);
    await _snap(t, name);
  });

  _s('78_picture_picker_dark', (t) async {
    const name = '78_picture_picker_dark';
    final m = await _picturesModel();
    await _frame(t, _dark(m));
    // The Modern set: its dark backgrounds against the dark theme, with the ring that keeps them apart
    await _openPicker(t, set: 'set2');
    await _snap(t, name);
  });

  // Jordan's group chat with pictures: Jordan's photo in the list and the header, his agents' drawn pictures with the
  // agent badge, my agents' pictures on my side, none on my own messages.
  _s('79_chat_pictures', (t) async {
    const name = '79_chat_pictures';
    final m = await _picturesModel();
    await m.select(jordanTeam.linkId, chat: const ThreadKey.agent('claude-backend'));
    await _frame(t, XApp(model: m));
    await _decodeImages(t);
    await _snap(t, name);
  });

  _s('79_chat_pictures_dark', (t) async {
    const name = '79_chat_pictures_dark';
    final m = await _picturesModel();
    await m.select(jordanTeam.linkId, chat: const ThreadKey.agent('claude-backend'));
    await _frame(t, _dark(m));
    await _decodeImages(t);
    await _snap(t, name);
  });

  _s('80_settings_profile', (t) async {
    const name = '80_settings_profile';
    final m = await _picturesModel();
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 400));
    await _decodeImages(t);
    await _snap(t, name);
  });

  // Use my photo…: the photo in the square, the circle contacts will see.
  _s('81_picture_crop', (t) async {
    const name = '81_picture_crop';
    final chooser = PhotoChooser.instance;
    PhotoChooser.instance = _GoldenPhotoChooser();
    addTearDown(() => PhotoChooser.instance = chooser);
    final m = await _picturesModel();
    await _frame(t, XApp(model: m));
    await _openPicker(t);
    await t.runAsync(() async {
      await t.tap(find.byKey(const Key('picture-photo')));
      for (var i = 0; i < 100 && find.byKey(const Key('picture-crop-viewport')).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await t.pump();
      }
    });
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });
}
