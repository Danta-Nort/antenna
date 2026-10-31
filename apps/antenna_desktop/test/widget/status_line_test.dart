// SPDX-License-Identifier: AGPL-3.0-only
// The node status at the bottom left ("relay n0 · 1 contact") counts the window's contact list, so it is right as
// soon as a pairing finishes, on either side, without waiting for the 10 s contacts poll. It used to show the
// `links` of the `status` reply read once at connect, which stayed at 0 after the first pairing on a new node.

import 'dart:async';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/pairing/pairing_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

final _alex = contact('Alex', 9001, trust: 2);

LinkedReply _linked() => LinkedReply(
      contact: 'Alex',
      linkId: _alex.linkId,
      trust: 2,
      netMode: 'relay_only',
      kxGroup: 'X25519MLKEM768',
      pairingMs: 2600,
    );

/// A new node: no contacts yet. `live: false`, so no poll runs: only the pairing itself may update the count.
Future<(AppModel, FakeDaemon)> _fresh(WidgetTester t) async {
  final d = FakeDaemon();
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
  return (m, d);
}

Finder _status(String text) =>
    find.descendant(of: find.byKey(const Key('daemon-pill')), matching: find.text('relay n0 · $text'));

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('inviter: the status line counts the new contact as soon as the pairing finishes', (t) async {
    final (_, d) = await _fresh(t);
    expect(_status(en.navContactsCount(0)), findsOneWidget);
    unawaited(showInviteDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('invite-create')));
    await t.pump();
    final dlg = d.dialogs.last
      ..emit(InviteCreated(id: 'i1', link: demoLink, expiresMs: ms(fixedNow) + 600000, trust: 2, netMode: 'relay_only'))
      ..emit(const SasEvent(code: '482913'))
      ..emit(const NeedInput('confirm', confirmWithoutCode: true));
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byKey(const Key('invite-confirm-match')));
    await t.pump();
    // The daemon created the link (the `status` reply would still say 0 links until the window asks again).
    d.contactList = [_alex];
    dlg.finish(_linked());
    await _settle(t);
    expect(_status(en.navContactsCount(1)), findsOneWidget);
    expect(find.text('relay n0 · 1 contact'), findsOneWidget);
  });

  testWidgets('joiner: the status line counts the new contact as soon as the pairing finishes', (t) async {
    final (_, d) = await _fresh(t);
    unawaited(showJoinDialog(t.element(find.byType(HomeScreen)), link: demoLink));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('join-start')));
    await t.pump();
    final dlg = d.dialogs.last..emit(const NeedInput('sas_code'));
    await t.pump(const Duration(milliseconds: 200));
    await t.enterText(find.byKey(const Key('sas-input')), '482913');
    await t.tap(find.byKey(const Key('sas-submit')));
    await t.pump();
    d.contactList = [contact('Alex', 9001, trust: 2, role: 'joiner')];
    dlg.finish(_linked());
    await _settle(t);
    expect(_status(en.navContactsCount(1)), findsOneWidget);
  });

  testWidgets('pending invite confirmed from the list: the count follows too', (t) async {
    final d = FakeDaemon(invites: [
      InviteInfo(
        id: 'inv-31d0',
        link: '',
        trust: 2,
        label: 'Alex',
        netMode: 'relay_only',
        createdMs: ms(fixedNow),
        expiresMs: ms(fixedNow) + 600000,
        phase: 'needs_confirm',
        confirmWithoutCode: true,
      ),
    ])
      ..pairedContact = _alex;
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m));
    await t.pump(const Duration(milliseconds: 400));
    unawaited(showInviteMonitor(t.element(find.byType(HomeScreen)), 'inv-31d0'));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('monitor-confirm-match')));
    await _settle(t);
    expect(_status(en.navContactsCount(1)), findsOneWidget);
  });
}
