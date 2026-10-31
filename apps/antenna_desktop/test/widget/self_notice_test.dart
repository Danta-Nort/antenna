// SPDX-License-Identifier: AGPL-3.0-only
// The one-time notice about contacts already at level 5 (it now also sends secrets without asking): on the first
// window start with this meaning it lists them; Keep sends nothing, Lower to 4 is the trust command with the owner
// password; the window remembers that it was shown and never shows it again. Without level-5 contacts it is not shown
// and is marked as shown, so a later level-5 contact gets the ordinary level-5 warning instead.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

final studio = contact('studio-mac', 61, trust: 5, lamport: 4);

Future<(AppModel, FakeDaemon)> _model(List<ContactInfo> contacts) async {
  final d = FakeDaemon(contacts: contacts, history: demoHistory());
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return (m, d);
}

Future<void> _start(WidgetTester t, AppModel m, Appearance look) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: look));
  await t.pump(const Duration(milliseconds: 400));
  // The notice opens after the frame in which the contacts became known.
  await t.pump(const Duration(milliseconds: 300));
}

AppearanceStore _store() {
  final dir = Directory.systemTemp.createTempSync('antenna-self-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return AppearanceStore('${dir.path}/window.json');
}

Map<String, Object?> _file(AppearanceStore s) => json.decode(File(s.path).readAsStringSync()) as Map<String, Object?>;

final _notice = find.byKey(const Key('self-notice'));

Future<void> _tap(WidgetTester t, String key) async {
  await t.tap(find.byKey(Key(key)));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('shown once with the level-5 contacts; Keep sends nothing; Lower to 4 asks the password', (t) async {
    final store = _store();
    final (m, d) = await _model([...demoContacts(), studio]);
    await _start(t, m, Appearance.load(store));
    expect(_notice, findsOneWidget);
    expect(find.text(en.selfNoticeTitle), findsOneWidget);
    expect(en.selfNoticeTitle, '∞ My computer now also sends secrets without asking: keep it or lower to 4');
    // Exactly the contacts at level 5.
    expect(find.byKey(Key('self-notice-$buildBotName')), findsOneWidget);
    expect(find.byKey(const Key('self-notice-studio-mac')), findsOneWidget);
    expect(find.byKey(Key('self-notice-$emilyName')), findsNothing, reason: 'level 4');
    expect(_file(store)['self_notice_shown'], isTrue, reason: 'remembered as soon as it is shown');
    // Keep: nothing to send.
    await _tap(t, 'self-keep-$buildBotName');
    expect(find.byKey(Key('self-kept-$buildBotName')), findsOneWidget);
    expect(d.calls, isNot(contains('trust')));
    // Lower to 4: the password, then `trust … 4`.
    await _tap(t, 'self-lower-studio-mac');
    expect(find.byKey(const Key('owner-password')), findsOneWidget);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await _tap(t, 'password-ok');
    expect(d.calls.where((c) => c == 'trust'), hasLength(1));
    expect(d.passwords['trust'], d.password);
    expect(m.contacts.firstWhere((c) => c.label == 'studio-mac').trust, 4);
    expect(m.contacts.firstWhere((c) => c.label == buildBotName).trust, 5);
    expect(find.byKey(const Key('self-lowered-studio-mac')), findsOneWidget);
    await _tap(t, 'self-notice-done');
    await t.pump(const Duration(milliseconds: 300));
    expect(_notice, findsNothing);

    // The next start: not again.
    final (m2, _) = await _model([...demoContacts(), studio]);
    await _start(t, m2, Appearance.load(store));
    await t.pump(const Duration(milliseconds: 300));
    expect(_notice, findsNothing);
  });

  testWidgets('a wrong password leaves the contact at 5 and says why', (t) async {
    final (m, d) = await _model([...demoContacts()]);
    await _start(t, m, Appearance.load(_store()));
    await _tap(t, 'self-lower-$buildBotName');
    await t.enterText(find.byKey(const Key('owner-password')), 'not the password');
    await _tap(t, 'password-ok');
    expect(find.text(en.errWrongPassword), findsOneWidget);
    expect(m.contacts.firstWhere((c) => c.label == buildBotName).trust, 5);
    expect(find.byKey(Key('self-lower-$buildBotName')), findsOneWidget, reason: 'the owner can try again');
    expect(d.calls.where((c) => c == 'trust'), hasLength(1));
  });

  testWidgets('no level-5 contact: no notice, but it is settled; a later level 5 gets the ordinary warning',
      (t) async {
    final store = _store();
    final (m, _) = await _model([emily, jordan, ryan]);
    final look = Appearance.load(store);
    await _start(t, m, look);
    await t.pump(const Duration(milliseconds: 300));
    expect(_notice, findsNothing);
    expect(_file(store)['self_notice_shown'], isTrue);
    expect(look.selfNoticeDue, isFalse);
    // Picking level 5 now shows the warning of the picker, not the notice.
    await m.select(jordan.linkId);
    await t.pump(const Duration(milliseconds: 300));
    await _tap(t, 'card-toggle');
    await _tap(t, 'trust-edit');
    await _tap(t, 'trust-5');
    expect(find.byKey(const Key('self-warning')), findsOneWidget);
    expect(_notice, findsNothing);
    await _tap(t, 'self-cancel');
  });

  testWidgets('the notice waits for the contacts; without a settings file it is not shown at all', (t) async {
    // Keys still locked: no contacts yet, no notice and nothing remembered.
    final store = _store();
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), state: DaemonState.locked);
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    final look = Appearance.load(store);
    await _start(t, m, look);
    expect(_notice, findsNothing);
    expect(look.selfNoticeDue, isTrue);
    expect(await m.unlock(d.password), isNull);
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 400));
    expect(_notice, findsOneWidget, reason: 'after unlocking, once the contacts are known');
    await _tap(t, 'self-notice-done');

    final (m2, _) = await _model(demoContacts());
    await _start(t, m2, Appearance());
    await t.pump(const Duration(milliseconds: 300));
    expect(_notice, findsNothing, reason: 'nowhere to remember it: like the Code mode offer, not shown');
  });
}
