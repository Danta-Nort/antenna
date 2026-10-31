// SPDX-License-Identifier: AGPL-3.0-only
// Withdrawing a sent file the contact has not answered (preview.5, CONTROL §14, fake daemon): "Cancel sending" on the
// sender's card and both answers of `file_withdraw` (`contact_notified`, `contact_cannot_withdraw`, with the note
// shown before for a contact whose node cannot delete its copy); the receiver's card after the `file` event; both
// sides after a reload, from the `withdraw_file` receipts in the history; a file answered meanwhile (`not_found`); an
// older daemon (`unknown_command`: the button goes).

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/files.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

Future<AppModel> _model(FakeDaemon d, String linkId) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  await m.select(linkId);
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
}

String _k(FileInfo f) => f.id.substring(0, 8);

FakeDaemon _demo({List<ContactInfo>? contacts}) {
  final d = FakeDaemon(contacts: contacts ?? demoContacts(), history: demoHistory());
  addDemoFiles(d);
  return d;
}

/// A contact on an older release: its node cannot delete a pending copy.
final mia = contact('Mia Chen', 77, peerFileWithdraw: false);

FileInfo get _toMia => demoFile(70,
    from: mia,
    direction: 'out',
    name: 'floor-plan.pdf',
    size: 90000,
    mime: 'application/pdf',
    state: 'sent',
    verdict: 'clean',
    at: ago(minutes: 3));

void main() {
  testWidgets('sender: "Cancel sending" withdraws an unanswered file, and the card says it is no longer offered',
      (t) async {
    final d = _demo();
    final m = await _model(d, jordan.linkId);
    await _app(t, m);
    expect(find.text(en.filesWithdrawOldContact), findsNothing, reason: 'Jordan\'s node can delete its copy');
    await t.tap(find.byKey(Key('file-withdraw-${_k(sentNotes)}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls, contains('file_withdraw'));
    expect(m.files[sentNotes.id]!.state, 'withdrawn');
    expect(m.files[sentNotes.id]!.withdrawal, 'contact_notified');
    expect(find.text(en.filesOutWithdrawn), findsOneWidget);
    expect(find.text(en.filesOutWithdrawnOld), findsNothing);
    expect(find.byKey(Key('file-withdraw-${_k(sentNotes)}')), findsNothing);
  });

  testWidgets('an older contact: the note says a copy may stay, before and after the withdrawal', (t) async {
    final d = _demo(contacts: [...demoContacts(), mia]);
    d.fileMap[_toMia.id] = _toMia;
    d.historyMap[mia.linkId] = [fileMsg(3, _toMia, ago(minutes: 3))];
    final m = await _model(d, mia.linkId);
    await _app(t, m);
    expect(find.text(en.filesWithdrawOldContact), findsOneWidget);
    await t.tap(find.byKey(Key('file-withdraw-${_k(_toMia)}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.files[_toMia.id]!.withdrawal, 'contact_cannot_withdraw');
    expect(find.text(en.filesOutWithdrawn), findsOneWidget);
    expect(find.text(en.filesOutWithdrawnOld), findsOneWidget);
  });

  testWidgets('receiver: a withdrawn file says so and can no longer be accepted', (t) async {
    final d = _demo();
    final m = await _model(d, emily.linkId);
    await _app(t, m);
    expect(find.byKey(Key('file-accept-${_k(contractPdf)}')), findsOneWidget);
    m.handleEvent(FileEvent(contact: emily.label, linkId: emily.linkId, file: contractPdf.withState('withdrawn')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.filesInWithdrawn), findsOneWidget);
    expect(find.byKey(Key('file-accept-${_k(contractPdf)}')), findsNothing);
    expect(find.byKey(Key('file-preview-${_k(contractPdf)}')), findsNothing);
    expect(m.filesAwaiting.where((f) => f.id == contractPdf.id), isEmpty);
  });

  testWidgets('after a reload the withdraw_file receipts mark both sides', (t) async {
    final d = _demo();
    d.historyMap[jordan.linkId] = [
      ...d.historyMap[jordan.linkId]!,
      withdrawReceiptMsg(40, true, sentNotes.messageId!, ago(minutes: 1)),
    ];
    d.historyMap[emily.linkId] = [
      ...d.historyMap[emily.linkId]!,
      withdrawReceiptMsg(41, false, contractPdf.messageId!, ago(minutes: 1)),
    ];
    final m = await _model(d, jordan.linkId);
    await m.select(emily.linkId);
    await _app(t, m);
    expect(m.files[sentNotes.id]!.state, 'withdrawn', reason: 'our own receipt');
    expect(m.files[contractPdf.id]!.state, 'withdrawn', reason: 'the sender\'s receipt');
    expect(find.text(en.filesInWithdrawn), findsOneWidget);
    expect(find.textContaining('${en.receiptWithdrewFile}: ${en.receiptWithdrawn}'), findsOneWidget,
        reason: 'the receipt line in plain words');
  });

  testWidgets('the receiver after a reload: the offer the daemon no longer lists is a withdrawn card', (t) async {
    final d = _demo();
    // The sender withdrew it; this node deleted its copy, so files_pending does not list it any more.
    d.fileMap.remove(contractPdf.id);
    d.historyMap[emily.linkId] = [
      ...d.historyMap[emily.linkId]!,
      withdrawReceiptMsg(41, false, contractPdf.messageId!, ago(minutes: 1)),
    ];
    final m = await _model(d, emily.linkId);
    await _app(t, m);
    final card = m.fileByMessage(contractPdf.messageId!)!;
    expect((card.name, card.size, card.state, card.incoming), ('contract_v7.pdf', 421888, 'withdrawn', true));
    expect(find.text('contract_v7.pdf'), findsOneWidget, reason: 'a card, not the raw history line');
    expect(find.text(en.filesInWithdrawn), findsOneWidget);
    expect(withdrawnOfferFrom(msg(1, false, 'file: a (b).txt (12 bytes, text/plain, blake3 00ff00ff00ff00ff)', fixedNow))
        ?.name, 'a (b).txt');
    expect(withdrawnOfferFrom(msg(1, false, 'just text', fixedNow)), isNull);
  });

  testWidgets('answered meanwhile: not_found says there is nothing to withdraw', (t) async {
    final d = _demo();
    final m = await _model(d, jordan.linkId);
    await _app(t, m);
    // The contact accepted it a moment ago; the receipt has not reached the window yet.
    d.fileMap[sentNotes.id] = sentNotes.withState('accepted');
    await t.tap(find.byKey(Key('file-withdraw-${_k(sentNotes)}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.filesWithdrawNotFound), findsOneWidget);
    expect(m.files[sentNotes.id]!.state, 'sent');
  });

  testWidgets('an older daemon (unknown_command): the button goes away and says to update', (t) async {
    final d = _demo()..withdrawSupported = false;
    final m = await _model(d, jordan.linkId);
    await _app(t, m);
    await t.tap(find.byKey(Key('file-withdraw-${_k(sentNotes)}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.filesWithdrawUnsupported), findsOneWidget);
    expect(m.fileWithdrawSupported, isFalse);
    expect(find.byKey(Key('file-withdraw-${_k(sentNotes)}')), findsNothing);
  });
}
