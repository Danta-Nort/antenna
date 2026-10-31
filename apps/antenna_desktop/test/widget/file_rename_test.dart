// SPDX-License-Identifier: AGPL-3.0-only
// A received file whose name is taken in the link folder (CONTROL §14 "A name that is taken", D-UI-29), on the fake
// daemon: the same file is accepted with one click and the card says so (preview.8 daemon: `duplicate`), also before
// the click (`file_name_check`); a different file under the name opens "Another name" with the daemon's free
// suggestion, checks each edit, keeps Accept disabled with the reason while the name is taken or invalid, and shows
// every refusal of the accept itself. The maintainer's finding (a preview.5 window on the Mac: identical re-sent release
// files, the rename dialog with the same name prefilled, Accept did nothing) is the first test: it failed before the
// fix (the window sent the refused name again and, after three tries, closed the dialog without a word).

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/files/rename_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _dmg = 'Antenna-0.1.3-macos-arm64.dmg';

FileInfo _copy(int seed, {String name = _dmg, String? blake3}) {
  final f = demoFile(seed,
      from: emily,
      name: name,
      size: 48700249,
      mime: 'application/x-apple-diskimage',
      state: 'checked',
      verdict: 'suspicious',
      at: ago(minutes: 10 - seed));
  return blake3 == null ? f : _withBlake3(f, blake3);
}

FileInfo _withBlake3(FileInfo f, String b) => FileInfo(
    id: f.id,
    contact: f.contact,
    linkId: f.linkId,
    direction: f.direction,
    name: f.name,
    size: f.size,
    blake3: b,
    state: f.state,
    createdMs: f.createdMs,
    senderMime: f.senderMime,
    verdict: f.verdict,
    mime: f.mime,
    messageId: f.messageId);

/// Emily's link folder already holds [name] with content [blake3]. The daemon is one before D-128, which answers
/// `file_name_taken` for a name another file has (a D-128 daemon numbers it: file_numbered_name_test.dart), so these
/// tests cover the window's fallback, "Another name", for such a daemon.
FakeDaemon _daemon(List<FileInfo> files, {required String name, required String blake3, int proto = 7}) {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..protoVersion = proto
    ..numbersTakenNames = false;
  for (final f in files) {
    d.fileMap[f.id] = f;
  }
  d.folderFiles[emily.linkId] = {name.toLowerCase(): blake3};
  return d;
}

Future<AppModel> _app(WidgetTester t, FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  t.view.physicalSize = const Size(1440, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('nav-files')));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
  return m;
}

String _k(FileInfo f) => f.id.substring(0, 8);

Future<void> _acceptOnCard(WidgetTester t, FileInfo f) async {
  await t.ensureVisible(find.byKey(Key('file-accept-${_k(f)}')));
  await t.tap(find.byKey(Key('file-accept-${_k(f)}')));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(FileRenameDialog.debounce);
  await t.pump(const Duration(milliseconds: 100));
}

/// Type [name] into the dialog and let the check answer.
Future<void> _type(WidgetTester t, String name) async {
  await t.enterText(find.byKey(const Key('file-name')), name);
  await t.pump(FileRenameDialog.debounce);
  await t.pump(const Duration(milliseconds: 100));
}

/// Accept in the dialog; the accept answers, then the dialog's closing animation runs.
Future<void> _closes(WidgetTester t) async {
  await t.tap(find.byKey(const Key('file-rename-accept')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

bool _acceptEnabled(WidgetTester t) => t.widget<ButtonStyleButton>(find.byKey(const Key('file-rename-accept'))).enabled;

String _status(WidgetTester t) => t.widget<Text>(find.byKey(const Key('file-rename-status'))).data!;

void main() {
  testWidgets('the Mac finding: an identical re-sent file on a preview.5-like daemon never makes Accept a silent no-op',
      (t) async {
    final first = _copy(1);
    // A daemon without file_name_check and without `duplicate`: it refuses the same file under the same name as taken.
    final d = _daemon([first], name: _dmg, blake3: first.blake3, proto: 6);
    await _app(t, d);
    await _acceptOnCard(t, first);
    expect(d.acceptNames, [null], reason: 'Accept on the card first, under the contact\'s name');
    // Only what the preview.5 window had too (the field, the button's text), so this part also ran against it.
    final field = find.byKey(const Key('file-name'));
    final accept = find.widgetWithText(FilledButton, en.filesRenameAccept);
    expect(field, findsOneWidget);
    expect(t.widget<TextField>(field).controller!.text, _dmg, reason: 'the refused name, as the daemon has it');
    for (var i = 0; i < 3; i++) {
      await t.tap(accept, warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(FileRenameDialog.debounce);
    }
    expect(d.acceptNames, [null], reason: 'the refused name is never sent again (preview.5 sent it three times)');
    expect(d.nameChecks, isEmpty, reason: 'an older daemon is never asked to check a name');
    expect(field, findsOneWidget, reason: 'the dialog stays (preview.5 closed it after the third try, saying nothing)');
    // Why Accept does nothing: it is disabled, and the dialog says so.
    expect(_acceptEnabled(t), isFalse);
    expect(_status(t), en.filesRenameRefused);
    // Another name: the daemon accepts it.
    await _type(t, 'Antenna-0.1.3-macos-arm64 (copy).dmg');
    expect(_acceptEnabled(t), isTrue);
    expect(_status(t), en.filesRenameNoCheck);
    await _closes(t);
    expect(d.acceptNames.last, 'Antenna-0.1.3-macos-arm64 (copy).dmg');
    expect(find.byKey(const Key('file-rename-dialog')), findsNothing);
    expect(d.fileMap[first.id]!.state, 'accepted');
  });

  testWidgets('the same file on a preview.8 daemon: said on the card before the click, accepted with one click',
      (t) async {
    final copy = _copy(2);
    final d = _daemon([copy], name: _dmg, blake3: copy.blake3);
    final m = await _app(t, d);
    expect(d.nameChecks, [null], reason: 'one check of the contact\'s name for the waiting card');
    expect(find.byKey(Key('file-same-${_k(copy)}')), findsOneWidget);
    expect(find.text(en.filesSameAlready), findsOneWidget);
    await _acceptOnCard(t, copy);
    expect(find.byKey(const Key('file-rename-dialog')), findsNothing, reason: 'no rename dialog for the same file');
    expect(d.acceptNames, [null]);
    expect(m.files[copy.id]!.duplicate, isTrue);
    expect(find.byKey(Key('file-duplicate-${_k(copy)}')), findsOneWidget);
    expect(find.text(en.filesAcceptedSame('shared')), findsOneWidget);
  });

  testWidgets('a different file under the name: the daemon\'s suggestion, each edit checked, the reason while blocked',
      (t) async {
    final other = _copy(3, name: 'report.pdf');
    final d = _daemon([other], name: 'Report.PDF', blake3: hex(0xDEAD));
    d.folderFiles[emily.linkId]!['report (2).pdf'] = hex(0xBEEF);
    await _app(t, d);
    expect(find.byKey(Key('file-same-${_k(other)}')), findsNothing, reason: 'another file, not the same one');
    await _acceptOnCard(t, other);
    expect(find.text(en.filesRenameWhyTaken('report.pdf')), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('file-name'))).controller!.text, 'report (3).pdf',
        reason: 'prefilled with the daemon\'s first free name');
    expect(_status(t), en.filesRenameFree);
    expect(_acceptEnabled(t), isTrue);

    await _type(t, 'REPORT.pdf');
    expect(_status(t), en.filesRenameTaken, reason: 'taken ignoring case');
    expect(_acceptEnabled(t), isFalse);
    expect(find.text(en.filesRenameUse('REPORT (3).pdf')), findsOneWidget);

    await _type(t, 'a/b.pdf');
    expect(_status(t), en.filesRenameInvalid('a name cannot contain / or \\'));
    expect(_acceptEnabled(t), isFalse);

    await t.enterText(find.byKey(const Key('file-name')), 'notes.pdf');
    await t.pump(const Duration(milliseconds: 50));
    expect(_acceptEnabled(t), isFalse, reason: 'not before the check answered');
    expect(_status(t), en.filesRenameChecking);
    await t.pump(FileRenameDialog.debounce);
    await t.pump(const Duration(milliseconds: 100));
    expect(_status(t), en.filesRenameFree);
    await _closes(t);
    expect(d.acceptNames, [null, 'notes.pdf']);
    expect(find.byKey(const Key('file-rename-dialog')), findsNothing);
  });

  testWidgets('a refusal of the accept itself is shown in the dialog, which stays open', (t) async {
    final other = _copy(4, name: 'report.pdf');
    final d = _daemon([other], name: 'report.pdf', blake3: hex(0xDEAD));
    await _app(t, d);
    await _acceptOnCard(t, other);
    expect(_acceptEnabled(t), isTrue);
    // Another process takes the name between the check and the accept.
    d.acceptRace = true;
    await t.tap(find.byKey(const Key('file-rename-accept')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('file-rename-dialog')), findsOneWidget);
    expect(find.byKey(const Key('file-rename-error')), findsOneWidget);
    expect(find.textContaining(en.filesErrNameTaken), findsOneWidget);
    expect(_acceptEnabled(t), isFalse, reason: 'that name was refused: it is not sent again as it is');
    d.acceptRace = false;
    await _type(t, 'report-final.pdf');
    await _closes(t);
    expect(find.byKey(const Key('file-rename-dialog')), findsNothing);
    expect(d.fileMap[other.id]!.savedAs, 'report-final.pdf');
  });
}
