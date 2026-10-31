// SPDX-License-Identifier: AGPL-3.0-only
// A received file the own-computer rules hold (D-130), on the fake daemon: the card says what the danger is, as a
// browser's download warning does (a program, an installer, an archive Antenna could not look inside, a threat
// signature, a failed check), with the rules small, and offers Delete and Keep anyway, never Accept. Keep anyway asks
// the owner password and sends `force`; Delete asks nothing; nothing on the card takes the focus, and Delete comes
// first. What the check noted without holding the file shows as quiet labels, and code reads "Code: Antenna does not
// run it".

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

/// A checked file from the build server (∞) with what the daemon says about it.
FileInfo _file(int seed, String name,
    {FileHeld? held,
    List<String> labels = const [],
    String? fileClass,
    String? mime = 'application/zip',
    String verdict = 'clean'}) {
  final base = demoFile(seed,
      from: buildBot,
      name: name,
      size: 52000,
      mime: mime ?? '',
      state: 'checked',
      verdict: verdict,
      at: ago(minutes: 5));
  return FileInfo(
    id: base.id,
    contact: base.contact,
    linkId: base.linkId,
    direction: base.direction,
    name: base.name,
    size: base.size,
    blake3: base.blake3,
    state: base.state,
    createdMs: base.createdMs,
    verdict: base.verdict,
    mime: mime,
    messageId: base.messageId,
    held: held,
    labels: labels,
    fileClass: fileClass,
  );
}

String _k(FileInfo f) => f.id.substring(0, 8);

Future<(AppModel, FakeDaemon)> _app(WidgetTester t, List<FileInfo> files) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  for (final f in files) {
    d.fileMap[f.id] = f;
  }
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  t.view.physicalSize = const Size(1440, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('nav-files')));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
  return (m, d);
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('each held reason reads as a warning with its rules, and offers Delete and Keep anyway', (t) async {
    final program =
        _file(1, 'tool', mime: 'application/x-executable', held: const FileHeld(code: 'executable', rules: ['elf']));
    final bare = _file(2, 'run.bin', mime: null, held: const FileHeld(code: 'executable'));
    final installer =
        _file(3, 'App.dmg', held: const FileHeld(code: 'installer', rules: ['disk_image', 'archive_member_installer']));
    final sealed = _file(4, 'backup.zip', held: const FileHeld(code: 'uninspected', rules: ['archive_encrypted']));
    final threat = _file(5, 'notes.txt', verdict: 'threat', held: const FileHeld(code: 'threat', rules: ['eicar']));
    final failed = _file(6, 'big.iso', verdict: 'failed', held: const FileHeld(code: 'check_failed'));
    await _app(t, [program, bare, installer, sealed, threat, failed]);
    final texts = {
      program: en.filesHeldExecutable('application/x-executable'),
      bare: en.filesHeldExecutableNoMime,
      installer: en.filesHeldInstaller,
      sealed: en.filesHeldUninspected,
      threat: en.filesHeldThreat,
      failed: en.filesHeldCheckFailed,
    };
    for (final MapEntry(key: f, value: text) in texts.entries) {
      expect(find.byKey(Key('file-warning-${_k(f)}')), findsOneWidget, reason: f.name);
      expect(find.descendant(of: find.byKey(Key('file-warning-${_k(f)}')), matching: find.text(text)), findsOneWidget,
          reason: f.name);
      expect(find.byKey(Key('file-delete-${_k(f)}')), findsOneWidget, reason: f.name);
      expect(find.byKey(Key('file-keep-${_k(f)}')), findsOneWidget, reason: f.name);
      expect(find.byKey(Key('file-accept-${_k(f)}')), findsNothing, reason: '${f.name}: no plain Accept');
    }
    expect(find.text(en.filesRules('elf')), findsOneWidget);
    expect(find.text(en.filesRules('disk_image, archive_member_installer')), findsOneWidget);
    expect(find.text(en.filesRules('archive_encrypted')), findsOneWidget);
    expect(find.text(en.filesRules('eicar')), findsOneWidget);
    expect(find.text(en.filesHeldKeepNote), findsNWidgets(6));
    expect(find.text(en.filesReject), findsNothing, reason: 'a warning, not a refusal');
  });

  testWidgets('Keep anyway asks the password and sends force; Cancel keeps nothing', (t) async {
    final f =
        _file(7, 'prototypes.zip', held: const FileHeld(code: 'executable', rules: ['archive_member_executable']));
    final (m, d) = await _app(t, [f]);
    await _tap(t, find.byKey(Key('file-keep-${_k(f)}')));
    expect(find.text(en.filesKeepAction('prototypes.zip')), findsOneWidget);
    await t.tap(find.text(en.commonCancel));
    await t.pump(const Duration(milliseconds: 400));
    expect(d.calls, isNot(contains('file_accept')), reason: 'cancelled: nothing sent');
    await _tap(t, find.byKey(Key('file-keep-${_k(f)}')));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await _tap(t, find.byKey(const Key('password-ok')));
    expect(d.acceptForces, [true]);
    expect(d.passwords['file_accept'], d.password);
    expect(m.files[f.id]!.state, 'accepted');
    expect(find.byKey(Key('file-warning-${_k(f)}')), findsNothing);
  });

  testWidgets('Delete asks nothing; nothing on the card takes the focus, and Delete comes first', (t) async {
    final f = _file(8, 'App.pkg', held: const FileHeld(code: 'installer'));
    final (m, d) = await _app(t, [f]);
    final keep = find.byKey(Key('file-keep-${_k(f)}'));
    final delete = find.byKey(Key('file-delete-${_k(f)}'));
    expect(t.widget<OutlinedButton>(keep).autofocus, isFalse);
    final keepNode = Focus.of(t.element(find.descendant(of: keep, matching: find.text(en.filesKeepAnyway))));
    expect(keepNode.hasFocus, isFalse, reason: 'Enter must never keep it');
    expect(t.getTopLeft(delete).dx, lessThan(t.getTopLeft(keep).dx), reason: 'Delete first');
    await _tap(t, delete);
    expect(find.byKey(const Key('owner-password')), findsNothing, reason: 'deleting needs no password');
    expect(d.calls, contains('file_reject'));
    expect(d.calls, isNot(contains('file_accept')));
    expect(m.files[f.id]!.state, 'rejected');
  });

  testWidgets('labels of a file the check did not hold are quiet chips; code says Antenna does not run it', (t) async {
    final page = _file(9, 'index.html',
        mime: 'text/html', fileClass: 'code', labels: ['active_content', 'polyglot_html'], verdict: 'suspicious');
    final text = _file(10, 'readme.txt', mime: 'text/plain', fileClass: 'text');
    await _app(t, [page, text]);
    expect(find.byKey(Key('file-labels-${_k(page)}')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('file-labels-${_k(page)}')), matching: find.text('active_content')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('file-labels-${_k(page)}')), matching: find.text('polyglot_html')),
        findsOneWidget);
    expect(find.byKey(Key('file-code-${_k(page)}')), findsOneWidget);
    expect(find.text(en.filesClassCode), findsOneWidget, reason: 'only the code file');
    expect(find.byKey(Key('file-warning-${_k(page)}')), findsNothing, reason: 'labels do not hold it');
    expect(find.byKey(Key('file-accept-${_k(page)}')), findsOneWidget, reason: 'the usual decision');
    expect(find.byKey(Key('file-labels-${_k(text)}')), findsNothing);
    expect(find.byKey(Key('file-code-${_k(text)}')), findsNothing);
  });
}
