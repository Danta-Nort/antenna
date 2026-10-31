// SPDX-License-Identifier: AGPL-3.0-only
// A received file whose name another file has (D-128), on the fake daemon: the daemon saves it under the next free
// number, so Accept opens no dialog and the card says "Saved as report (3).pdf"; "Another name" still opens for a name
// the daemon cannot use; a file from an own computer the daemon could not save by itself waits with the reason; and a
// sent file the contact's node numbered says under which name it was saved. The field report of 2026-10-06 (the
// "Another name" dialog with the same name, three times, then nothing) is the first test: before the fix every taken
// name went through that dialog.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/files/file_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

FileInfo _incoming(int seed, String name) => demoFile(seed,
    from: emily,
    name: name,
    size: 2048,
    mime: 'application/pdf',
    state: 'checked',
    verdict: 'clean',
    at: ago(minutes: 10 - seed));

FakeDaemon _daemon(List<FileInfo> files, Map<String, String> folder) {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  for (final f in files) {
    d.fileMap[f.id] = f;
  }
  d.folderFiles[emily.linkId] = folder;
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
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  test('numbered names follow the daemon\'s rule', () {
    expect(numberedFileName('report.pdf', 2), 'report (2).pdf');
    expect(numberedFileName('backup.tar.gz', 3), 'backup (3).tar.gz');
    expect(numberedFileName('.env', 2), '.env (2)');
    expect(numberedFileName('Makefile', 4), 'Makefile (4)');
    expect(numberedFileName('DECISIONS.md', 10), 'DECISIONS (10).md');
  });

  testWidgets('a taken name: no dialog, the daemon saves it under the next number and the card says so', (t) async {
    final f = _incoming(1, 'report.pdf');
    final d = _daemon([f], {'report.pdf': hex(0xDEAD), 'report (2).pdf': hex(0xBEEF)});
    final m = await _app(t, d);
    await _acceptOnCard(t, f);
    expect(find.byKey(const Key('file-rename-dialog')), findsNothing, reason: 'no "Another name" for a taken name');
    expect(d.acceptNames, [null], reason: 'one accept, under the contact\'s name');
    expect(m.files[f.id]!.savedAs, 'report (3).pdf');
    expect(find.byKey(Key('file-saved-as-${_k(f)}')), findsOneWidget);
    expect(find.text(en.filesSavedAsNumbered('report (3).pdf', 'shared')), findsOneWidget);
    expect(d.folderFiles[emily.linkId]!.keys, containsAll(['report.pdf', 'report (2).pdf', 'report (3).pdf']));
  });

  testWidgets('a name the daemon cannot use still opens "Another name"', (t) async {
    final f = _incoming(2, 'bad\u0001name.pdf');
    final d = _daemon([f], {});
    await _app(t, d);
    await _acceptOnCard(t, f);
    expect(find.byKey(const Key('file-rename-dialog')), findsOneWidget);
    expect(find.text(en.filesRenameWhyInvalid('bad\u0001name.pdf')), findsOneWidget);
  });

  testWidgets('a file from an own computer the daemon could not save waits on its card with the reason', (t) async {
    final base = _incoming(3, 'plan.txt');
    final f = FileInfo(
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
        messageId: base.messageId,
        held: const FileHeld(code: 'forbidden', message: 'destination is not a plain directory'));
    final d = _daemon([f], {});
    await _app(t, d);
    final reason = describeFileError(en, const XControlException('forbidden', 'destination is not a plain directory'));
    expect(find.byKey(Key('file-held-${_k(f)}')), findsOneWidget);
    expect(find.text(en.filesHeld(reason)), findsOneWidget);
    expect(find.byKey(Key('file-accept-${_k(f)}')), findsOneWidget, reason: 'the owner can still accept it');
  });

  testWidgets('a sent file the contact\'s node numbered says the name it was saved under', (t) async {
    final sent = demoFile(4,
        from: emily, name: 'DECISIONS.md', size: 900, mime: 'text/markdown', state: 'sent', at: ago(minutes: 3),
        direction: 'out');
    final plain = demoFile(5,
        from: emily, name: 'notes.md', size: 90, mime: 'text/markdown', state: 'sent', at: ago(minutes: 2),
        direction: 'out');
    final d = _daemon([sent, plain], {});
    final m = await _app(t, d);
    HistoryItem receipt(int seq, FileInfo f, int? number) => HistoryItem(
        seq: seq,
        id: hex(0xACC0 + seq, 64),
        direction: 'in',
        kind: 'receipt',
        text: '',
        ts: ms(ago(minutes: 1)),
        localMs: ms(ago(minutes: 1)),
        lamport: seq,
        status: 'received',
        receipt: ReceiptInfo(
            seq: seq,
            ts: ms(ago(minutes: 1)),
            actor: 'owner',
            action: 'accept_file',
            decision: 'accepted',
            reason: '',
            refs: [f.messageId!],
            nameNumber: number));
    m.handleEvent(MessageEvent(contact: emily.label, linkId: emily.linkId, message: receipt(900, sent, 2)));
    m.handleEvent(MessageEvent(contact: emily.label, linkId: emily.linkId, message: receipt(901, plain, null)));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.filesOutAcceptedAs('DECISIONS (2).md')), findsOneWidget);
    expect(find.byKey(Key('file-out-accepted-${_k(plain)}')), findsOneWidget);
    expect(find.text(en.filesOutAccepted), findsOneWidget, reason: 'the offered name: nothing more to say');
  });
}
