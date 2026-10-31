// SPDX-License-Identifier: AGPL-3.0-only
// Updates in the window on a stand-in `antenna update` CLI: the Settings card (versions, release key, "Check for
// updates" only with an update URL, an installation that cannot be updated, no CLI), the verify dialog (what the CLI
// verified, error codes in the window's language), the install (the owner password only on the CLI's stdin, the
// "Installing…" state) and a received release manifest in Files (a notice only when the CLI confirms the signature).

import 'dart:async';

import 'package:antenna_desktop/host/updater.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/updates/update_dialog.dart';
import 'package:antenna_desktop/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_updater.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

const _folder = '/Users/owner/Downloads/antenna-0.1.1';

class _FakePicker implements UpdatePicker {
  _FakePicker({this.manifestPath, this.folderPath});
  final String? manifestPath;
  final String? folderPath;
  final calls = <String>[];

  @override
  Future<String?> manifest(String confirm) async {
    calls.add('manifest');
    return manifestPath;
  }

  @override
  Future<String?> folder(String confirm) async {
    calls.add('folder');
    return folderPath;
  }
}

Future<AppModel> _model(FakeDaemon d, {AntennaUpdater? updater}) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, updater: updater);
  await m.connect();
  return m;
}

/// A tall window, so the whole Settings page (the Updates card is below the fold at 900 px) is built.
Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 2200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _settings(WidgetTester t) async {
  await t.tap(find.byKey(const Key('nav-settings')));
  await t.pump(const Duration(milliseconds: 400));
  // Updates are in Settings → Advanced.
  await t.tap(find.byKey(const Key('settings-advanced')));
  await t.pump(const Duration(milliseconds: 400));
  await t.pump();
}

Finder _inCard(Finder f) => find.descendant(of: find.byKey(const Key('updates-card')), matching: f);

/// Open the verify dialog for the release folder through "Install update from file…" → "Folder with the update…".
Future<void> _openFolder(WidgetTester t) async {
  await t.tap(find.byKey(const Key('update-from-file')));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('update-pick-folder')));
  await _dialog(t);
}

/// The picker answers, the dialog opens, the CLI's verify result arrives.
Future<void> _dialog(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  const cli = '$appPath/Contents/Helpers/antenna';
  FakeDaemon demo() => FakeDaemon(contacts: demoContacts(), history: demoHistory());

  tearDown(() => UpdatePicker.instance = _FakePicker());

  testWidgets('the Updates card: window and installed versions, release key; no "Check" without an update URL',
      (t) async {
    final f = FakeCli();
    final m = await _model(demo(), updater: f.updater());
    await _app(t, m);
    await _settings(t);
    expect(_inCard(find.text(en.updateTitle)), findsOneWidget);
    expect(_inCard(find.text(appVersionLine)), findsOneWidget);
    expect(_inCard(find.text('0.1.0-preview.2 (47cb9fa68c07)')), findsOneWidget);
    expect(_inCard(find.text(appPath)), findsOneWidget);
    expect(_inCard(find.text(en.updateKeyPinned('9f3c1a2b'))), findsOneWidget);
    expect(_inCard(find.text('0.1.0-preview.1 (1c63cc92d7bf)')), findsOneWidget);
    expect(find.byKey(const Key('update-check')), findsNothing, reason: 'no update URL configured');
    expect(t.widget<OutlinedButton>(find.byKey(const Key('update-from-file'))).onPressed, isNotNull);
    expect(f.calls, [
      [cli, 'update', '--json'],
    ]);
  });

  testWidgets('"Check for updates" appears with an update URL: a newer signed release, or up to date', (t) async {
    final f = FakeCli(status: statusJson(updateUrl: 'https://example.com/releases/latest.json'));
    final m = await _model(demo(), updater: f.updater());
    await _app(t, m);
    await _settings(t);
    await t.tap(find.byKey(const Key('update-check')));
    await t.pump(const Duration(milliseconds: 300));
    expect(f.calls.last, [cli, 'update', '--check', '--json']);
    expect(find.text(en.updateAvailable('0.1.1')), findsOneWidget);
    expect(_inCard(find.text(en.updateSignedBy('9f3c1a2b'))), findsOneWidget);
    expect(find.text('https://example.com/releases/0.1.1/$dmgName'), findsOneWidget);

    f.check = () => verifyJson(action: 'check', newer: false);
    await t.tap(find.byKey(const Key('update-check')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.updateUpToDate('0.1.0-preview.2')), findsOneWidget);
    expect(find.byKey(const Key('update-available')), findsNothing);

    f.check = () => errorJson('fetch_failed', 'GET https://example.com/releases/latest.json: 503');
    await t.tap(find.byKey(const Key('update-check')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.updateErrFetchFailed), findsOneWidget);
    expect(find.text('GET https://example.com/releases/latest.json: 503'), findsOneWidget);
  });

  testWidgets('install from a folder: the CLI verifies, the dialog shows version, channel, date, signature, file',
      (t) async {
    final f = FakeCli();
    final picker = _FakePicker(folderPath: _folder);
    UpdatePicker.instance = picker;
    final m = await _model(demo(), updater: f.updater());
    await _app(t, m);
    await _settings(t);
    await _openFolder(t);
    expect(picker.calls, ['folder']);
    expect(f.calls.last, [cli, 'update', '--from', _folder, '--dry-run', '--json']);
    final dialog = find.byKey(const Key('update-dialog'));
    Finder inDialog(String s) => find.descendant(of: dialog, matching: find.text(s));
    expect(inDialog('0.1.1'), findsOneWidget);
    expect(inDialog('preview'), findsOneWidget);
    expect(inDialog('Oct 10, 2026'), findsOneWidget);
    expect(inDialog(en.updateSignedBy('9f3c1a2b')), findsOneWidget);
    expect(inDialog('$dmgName · 46.4 MB'), findsOneWidget);
    expect(inDialog(appPath), findsOneWidget);
    expect(inDialog('· Mount the disk image read-only'), findsOneWidget);
    expect(t.widget<ButtonStyleButton>(find.byKey(const Key('update-install'))).onPressed, isNotNull);
  });

  testWidgets('error codes are shown in the window language, with the CLI text as details', (t) async {
    final f = FakeCli()
      ..verify = (_, {required manifestOnly}) => errorJson('no_release_key', 'this build has no release key pinned');
    UpdatePicker.instance = _FakePicker(folderPath: _folder);
    final m = await _model(demo(), updater: f.updater());
    await _app(t, m);
    await _settings(t);
    await _openFolder(t);
    expect(find.text(en.updateErrNoReleaseKey), findsOneWidget);
    expect(find.text('this build has no release key pinned'), findsOneWidget);
    expect(t.widget<ButtonStyleButton>(find.byKey(const Key('update-install'))).onPressed, isNull);
    await t.tap(find.text(en.commonCancel));
    await t.pump(const Duration(milliseconds: 300));

    // An unknown code: a generic message with the code, the CLI text under it.
    f.verify = (_, {required manifestOnly}) => errorJson('quota_exceeded', 'disk full');
    await _openFolder(t);
    expect(find.text(en.updateErrOther('quota_exceeded')), findsOneWidget);
    expect(find.text('disk full'), findsOneWidget);
  });

  testWidgets('Russian window: the error message is Russian', (t) async {
    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final f = FakeCli()..verify = (_, {required manifestOnly}) => errorJson('hash_mismatch', 'blake3 differs');
    UpdatePicker.instance = _FakePicker(folderPath: _folder);
    final m = await _model(demo(), updater: f.updater());
    await _app(t, m);
    await _settings(t);
    expect(_inCard(find.text(ru.updateTitle)), findsOneWidget);
    await _openFolder(t);
    expect(find.text(ru.updateErrHashMismatch), findsOneWidget);
    expect(find.text('blake3 differs'), findsOneWidget);
  });

  testWidgets('install: the owner password goes only to the CLI stdin; "Installing…" until it answers', (t) async {
    const password = 'correct horse battery';
    final f = FakeCli()..hold = Completer<void>();
    UpdatePicker.instance = _FakePicker(manifestPath: '$_folder/antenna-0.1.1-manifest.json');
    final m = await _model(demo(), updater: f.updater());
    await _app(t, m);
    await _settings(t);
    await t.tap(find.byKey(const Key('update-from-file')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('update-pick-manifest')));
    await _dialog(t);
    await t.tap(find.byKey(const Key('update-install')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.updateInstallAction('0.1.1')), findsOneWidget);
    await t.enterText(find.byKey(const Key('owner-password')), password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));

    final args = f.calls.last;
    expect(args, [
      cli, 'update', '--from', '$_folder/antenna-0.1.1-manifest.json', '--yes', '--password-stdin', '--json',
    ]);
    expect(f.calls.expand((c) => c).any((a) => a.contains(password)), isFalse, reason: 'never in arguments');
    expect(f.started.single.stdinText, '$password\n');
    expect(find.byKey(const Key('update-installing')), findsOneWidget);
    expect(find.text(en.updateInstallingNote), findsOneWidget);
    // The dialog cannot be dismissed while the install runs.
    expect(t.widget<TextButton>(find.widgetWithText(TextButton, en.commonCancel)).onPressed, isNull);
    await t.tapAt(const Offset(10, 10));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('update-dialog')), findsOneWidget);

    f.hold!.complete();
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(find.text(en.updateInstalled('0.1.1')), findsOneWidget);
    expect(find.byKey(const Key('update-installing')), findsNothing);
  });

  testWidgets('install: a wrong password comes back as an error, and the dialog stays', (t) async {
    final f = FakeCli()..install = (_) => errorJson('wrong_password', 'wrong owner password');
    UpdatePicker.instance = _FakePicker(folderPath: _folder);
    final m = await _model(demo(), updater: f.updater());
    await _app(t, m);
    await _settings(t);
    await _openFolder(t);
    await t.tap(find.byKey(const Key('update-install')));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), 'nope');
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(find.text(en.errWrongOwnerPassword), findsOneWidget);
    expect(t.widget<ButtonStyleButton>(find.byKey(const Key('update-install'))).onPressed, isNotNull);
  });

  testWidgets('an installation the CLI cannot update: its reason, and no install from a file', (t) async {
    const reason = 'Antenna runs from the mounted disk image; drag it to Applications first.';
    final f = FakeCli(status: statusJson(kind: 'unsupported', reason: reason));
    final m = await _model(demo(), updater: f.updater());
    await _app(t, m);
    await _settings(t);
    expect(find.text(en.updateUnsupported(reason)), findsOneWidget);
    expect(t.widget<OutlinedButton>(find.byKey(const Key('update-from-file'))).onPressed, isNull);
  });

  testWidgets('no CLI: one line instead of the update controls', (t) async {
    final m = await _model(demo());
    await _app(t, m);
    await _settings(t);
    expect(find.byKey(const Key('updates-no-cli')), findsOneWidget);
    expect(_inCard(find.text(appVersionLine)), findsOneWidget);
    expect(find.byKey(const Key('update-from-file')), findsNothing);
    expect(find.byKey(const Key('update-check')), findsNothing);
  });

  testWidgets('files: a verified release manifest gets a notice and Install; an unverified one gets nothing',
      (t) async {
    const good = '/home/owner/Antenna/links/Emily Carter/shared/antenna-0.1.1-manifest.json';
    const bad = '/home/owner/Antenna/links/Ryan Brooks/inbox/antenna-0.1.1-manifest.json';
    FileInfo manifest(int seed, ContactInfo from, String path) => FileInfo(
          id: hex(0x5E1EA5E + seed, 32),
          contact: from.label,
          linkId: from.linkId,
          direction: 'in',
          name: 'antenna-0.1.1-manifest.json',
          size: 1874,
          blake3: hex(0xB1 + seed),
          state: 'accepted',
          verdict: 'clean',
          mime: 'application/json',
          dest: path.contains('/shared/') ? 'shared' : 'inbox',
          savedAs: 'antenna-0.1.1-manifest.json',
          savedPath: path,
          createdMs: ms(ago(minutes: 3 + seed)),
        );
    final fromEmily = manifest(1, emily, good);
    final fromRyan = manifest(2, ryan, bad);
    // The disk image, still in quarantine: its BLAKE3 (checked by the daemon on download) is in the signed manifest.
    final dmg = FileInfo(
      id: hex(0xD1D1, 32),
      contact: emily.label,
      linkId: emily.linkId,
      direction: 'in',
      name: dmgName,
      size: 48700249,
      blake3: dmgBlake3,
      state: 'checked',
      verdict: 'suspicious',
      mime: 'application/x-apple-diskimage',
      createdMs: ms(ago(minutes: 2)),
    );
    final d = demo();
    for (final x in [fromEmily, fromRyan, dmg]) {
      d.fileMap[x.id] = x;
    }
    final f = FakeCli()
      ..verify = (paths, {required manifestOnly}) => !manifestOnly
          ? verifyJson(dir: paths.single)
          : paths.single == good
              ? verifyJson(asset: false)
              : errorJson('bad_signature', 'manifest signature does not verify');
    final m = await _model(d, updater: f.updater());
    await _app(t, m);
    await t.tap(find.byKey(const Key('nav-files')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));

    expect(f.calls.where((c) => c.contains('--manifest-only')).map((c) => c[3]).toSet(), {good, bad});
    Finder onCard(FileInfo x, Finder w) =>
        find.descendant(of: find.byKey(Key('file-${x.id.substring(0, 8)}')), matching: w);
    expect(onCard(fromEmily, find.text(en.updateFileVerified('0.1.1'))), findsOneWidget);
    expect(onCard(fromRyan, find.byKey(const Key('update-file-notice'))), findsNothing,
        reason: 'the CLI did not confirm the signature');
    expect(onCard(dmg, find.text(en.updateFilePart('0.1.1'))), findsOneWidget);

    await t.tap(onCard(fromEmily, find.byKey(const Key('update-file-install'))));
    await _dialog(t);
    expect(f.calls.last, [
      cli, 'update', '--from', '/home/owner/Antenna/links/Emily Carter/shared/antenna-0.1.1-manifest.json',
      '--dry-run', '--json',
    ]);
    expect(find.byKey(const Key('update-dialog')), findsOneWidget);
    expect(find.text(en.updateSignedBy('9f3c1a2b')), findsOneWidget);
  });

  testWidgets('files: no notice without a verified manifest, even for a file named like one', (t) async {
    const path = '/home/owner/Antenna/links/Emily Carter/shared/antenna-0.1.1-manifest.json';
    final x = FileInfo(
      id: hex(0xACCE, 32),
      contact: emily.label,
      linkId: emily.linkId,
      direction: 'in',
      name: 'antenna-0.1.1-manifest.json',
      size: 1874,
      blake3: hex(0xB2),
      state: 'accepted',
      dest: 'shared',
      savedAs: 'antenna-0.1.1-manifest.json',
      savedPath: path,
      createdMs: ms(ago(minutes: 1)),
    );
    final d = demo()..fileMap[x.id] = x;
    // The CLI answers ok but with an invalid signature: still not verified.
    final f = FakeCli()..verify = (_, {required manifestOnly}) => verifyJson(valid: false);
    final m = await _model(d, updater: f.updater());
    await _app(t, m);
    await t.tap(find.byKey(const Key('nav-files')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(f.calls.single, contains('--manifest-only'));
    expect(find.byKey(const Key('update-file-notice')), findsNothing);
  });
}
