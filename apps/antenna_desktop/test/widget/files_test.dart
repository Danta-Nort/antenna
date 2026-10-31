// SPDX-License-Identifier: AGPL-3.0-only
// Files in the window on the fake daemon (x-control/3): the card in the timeline and in the Files section, `file`
// events, accepting (normal; a threat only with the password and force; a special name with a separate permission),
// rejecting, the preview (with its plain notice), attaching with the paperclip and by drag and drop (sent on Send), and
// a secret in a file being sent (approval with the password on its chip, then a retry with approval_id).

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/files/file_actions.dart';
import 'package:antenna_desktop/ui/files/file_drop.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
}

FakeDaemon _demo() {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  addDemoFiles(d);
  return d;
}

String _k(FileInfo f) => f.id.substring(0, 8);

class _FakeChooser implements FileChooser {
  _FakeChooser(this.path);
  final String? path;
  int calls = 0;
  @override
  Future<String?> pick(String confirm) async {
    calls++;
    return path;
  }
}

void main() {
  testWidgets('a checked file shows in the chat as a card; accept puts it into shared/ (level 4)', (t) async {
    final d = _demo();
    final m = await _model(d);
    await m.select(emily.linkId);
    await _app(t, m);
    expect(find.byKey(Key('file-${_k(contractPdf)}')), findsOneWidget, reason: 'card instead of a text bubble');
    expect(find.byKey(Key('file-accept-${_k(contractPdf)}')), findsOneWidget);
    await t.tap(find.byKey(Key('file-accept-${_k(contractPdf)}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls, contains('file_accept'));
    expect(m.files[contractPdf.id]!.state, 'accepted');
    expect(m.files[contractPdf.id]!.dest, 'shared');
    expect(d.passwords.containsKey('file_accept'), isFalse, reason: 'a clean file needs no password');
    expect(find.byKey(Key('file-accept-${_k(contractPdf)}')), findsNothing);
  });

  testWidgets('a threat is accepted only with force and the owner password; reject needs nothing', (t) async {
    final d = _demo();
    final m = await _model(d);
    await m.select(jordan.linkId);
    await _app(t, m);
    await t.tap(find.byKey(Key('file-accept-${_k(disguisedExe)}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('owner-password')), findsOneWidget, reason: 'force → password first');
    expect(d.calls, isNot(contains('file_accept')));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.passwords['file_accept'], d.password);
    expect(m.files[disguisedExe.id]!.state, 'accepted');

    // Another file: reject.
    d.fileMap[disguisedExe.id] = disguisedExe;
    await m.refreshFiles();
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(Key('file-reject-${_k(disguisedExe)}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.files[disguisedExe.id]!.state, 'rejected');
  });

  testWidgets('a dot-file needs a separate permission (allow_special)', (t) async {
    final d = _demo();
    final dot = demoFile(40,
        from: emily, name: '.bashrc', size: 220, mime: 'text/plain', state: 'checked', verdict: 'clean', at: ago(minutes: 1));
    d.fileMap[dot.id] = dot;
    d.historyMap[emily.linkId] = [...d.historyMap[emily.linkId]!, fileMsg(50, dot, ago(minutes: 1))];
    final m = await _model(d);
    await m.select(emily.linkId);
    await _app(t, m);
    await t.tap(find.byKey(Key('file-accept-${_k(dot)}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('file-allow-special')), findsOneWidget);
    await t.tap(find.byKey(const Key('file-allow-special')));
    await t.pump(const Duration(milliseconds: 300));
    expect(m.files[dot.id]!.state, 'accepted');
  });

  testWidgets('preview is labelled honestly: rebuilt by the daemon, original stays in quarantine', (t) async {
    final d = _demo();
    final m = await _model(d);
    await m.select(ryan.linkId);
    await _app(t, m);
    await t.tap(find.byKey(Key('file-preview-${_k(macroSheet)}')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(d.calls, contains('file_preview'));
    expect(find.byKey(const Key('preview-honesty')), findsOneWidget);
    expect(find.byKey(const Key('preview-text')), findsOneWidget);
    // Level 2: accept into inbox/.
    expect(find.textContaining('inbox/'), findsWidgets);
  });

  testWidgets('file events move a card through the stages; the Files section counts what waits', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    final offered = demoFile(60,
        from: emily, name: 'plan.pdf', size: 1000, mime: 'application/pdf', state: 'offered', at: ago(minutes: 1));
    m.handleEvent(FileEvent(contact: emily.label, linkId: emily.linkId, file: offered));
    await t.pump();
    expect(m.filesAwaiting, isEmpty);
    m.handleEvent(FileEvent(
      contact: emily.label,
      linkId: emily.linkId,
      file: demoFile(60,
          from: emily,
          name: 'plan.pdf',
          size: 1000,
          mime: 'application/pdf',
          state: 'checked',
          verdict: 'clean',
          at: ago(minutes: 1)),
    ));
    await t.pump();
    expect(m.filesAwaiting.single.name, 'plan.pdf');
    await t.tap(find.byKey(const Key('nav-files')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(Key('file-${_k(offered)}')), findsOneWidget);
    expect(find.byKey(Key('file-accept-${_k(offered)}')), findsOneWidget);
  });

  testWidgets('paperclip and drag-and-drop attach files, Send sends them; a secret needs the owner approve, then a retry',
      (t) async {
    final d = _demo();
    const secret = '/home/owner/keys-backup.txt';
    d.shareNeedsApproval[secret] = 'ap-5e11c0';
    final m = await _model(d);
    await m.select(jordan.linkId);
    final chooser = _FakeChooser('/home/owner/report.pdf');
    FileChooser.instance = chooser;
    await _app(t, m);
    await t.tap(find.byKey(const Key('attach')));
    await t.pump(const Duration(milliseconds: 300));
    expect(chooser.calls, 1);
    expect(d.shared, isEmpty, reason: 'attached, not sent');
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.shared, ['/home/owner/report.pdf']);
    expect(m.filesOfLink(jordan.linkId).any((f) => f.name == 'report.pdf' && f.state == 'sent'), isTrue);

    // Drop the same path desktop_drop would deliver.
    await dropFilesForTest(t.element(find.byType(HomeScreen)), jordan.linkId, [secret]);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('send')));
    await t.pump(const Duration(milliseconds: 300));
    final held = m.stagedOf(jordan.linkId).single;
    expect(find.byKey(Key('attachment-approve-${held.id}')), findsOneWidget, reason: 'secret → approve, not a silent send');
    d.approvalList = [shareApproval('ap-5e11c0', to: jordan)];
    await t.tap(find.byKey(Key('attachment-approve-${held.id}')));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.passwords['approve'], d.password);
    expect(d.shared.where((p) => p == secret).length, 2, reason: 'retried with approval_id');
    expect(m.stagedOf(jordan.linkId), isEmpty);
    expect(find.byKey(Key('attachment-approve-${held.id}')), findsNothing);
  });
}
