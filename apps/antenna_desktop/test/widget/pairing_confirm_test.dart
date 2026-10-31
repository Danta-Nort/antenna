// SPDX-License-Identifier: AGPL-3.0-only
// Pairing confirmation on side A with one button (D-95): when the daemon says `confirm_without_code`, the owner
// clicks "The contact confirmed — codes match" and no code is sent; without the flag (an older daemon, or another
// invite showed a code at the same time) the code field as before; a refusal of the click (`code_required`, or
// `bad_request` from a daemon older than D-95) brings the code field back. The same for an invite confirmed from the
// pending invites list (`pairing_confirm`, with the password and without the code).

import 'dart:async';

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/pairing/pairing_dialogs.dart';
import 'package:antenna_desktop/ui/widgets/dialog_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _code = '482913';
const _linked = LinkedReply(
  contact: 'Alex',
  linkId: 'ab12',
  trust: 2,
  netMode: 'relay_only',
  kxGroup: 'X25519MLKEM768',
  pairingMs: 2600,
);

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

/// An invite from the window that reached the confirmation step: B entered the code A read out.
Future<FakeDialog> _inviteAtConfirm(WidgetTester t, FakeDaemon d, {required bool offered}) async {
  unawaited(showInviteDialog(t.element(find.byType(HomeScreen))));
  await t.pump(const Duration(milliseconds: 300));
  await t.enterText(find.byKey(const Key('invite-label')), 'Alex');
  await t.enterText(find.byKey(const Key('owner-password')), d.password);
  await t.tap(find.byKey(const Key('invite-create')));
  await t.pump();
  final dlg = d.dialogs.last
    ..emit(InviteCreated(id: 'i1', link: demoLink, expiresMs: ms(fixedNow) + 600000, trust: 2, netMode: 'relay_only'))
    ..emit(const SasEvent(code: _code))
    ..emit(const PeerEnteredCode())
    ..emit(NeedInput('confirm', confirmWithoutCode: offered));
  await t.pump(const Duration(milliseconds: 200));
  return dlg;
}

InviteInfo _pending({required bool offered}) => InviteInfo(
      id: 'inv-31d0',
      link: '',
      trust: 3,
      label: 'Alex',
      netMode: 'direct',
      createdMs: ms(fixedNow),
      expiresMs: ms(fixedNow) + 600000,
      phase: 'needs_confirm',
      sas: _code,
      confirmWithoutCode: offered,
    );

/// The reply, the contacts and history reloads after it, and the dialog's closing animation.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The pending invite (created with `antenna invite`), opened from the list.
Future<void> _openMonitor(WidgetTester t) async {
  unawaited(showInviteMonitor(t.element(find.byType(HomeScreen)), 'inv-31d0'));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('invite: with confirm_without_code, one button confirms and no code is sent', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    await _app(t, await _model(d));
    final dlg = await _inviteAtConfirm(t, d, offered: true);
    expect(find.text(en.pairPeerEnteredCodeMatch('Alex')), findsOneWidget);
    expect(find.byKey(const Key('invite-confirm-match')), findsOneWidget);
    expect(find.text(en.pairConfirmMatch), findsOneWidget);
    // No code field, and the code is not on screen: nothing to fill in.
    expect(find.byKey(const Key('sas-input')), findsNothing);
    expect(find.text('482 913'), findsNothing);
    expect(dlg.inputs, isEmpty, reason: 'nothing is confirmed before the click');
    expect(find.text(en.commonSameAs('antenna pairing confirm i1')), findsOneWidget);

    await t.tap(find.byKey(const Key('invite-confirm-match')));
    await t.pump();
    expect(dlg.inputs.single,
        isA<ConfirmInput>().having((i) => i.yes, 'yes', isTrue).having((i) => i.code, 'code', isNull));
    expect(dlg.inputs.single.toJson(), {
      'confirm': {'yes': true},
    });
    expect(d.calls, isNot(contains('pairing_confirm')), reason: 'on the follow connection, no second password');
    dlg.finish(_linked);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Linked with “Alex”'), findsOneWidget);
  });

  testWidgets('invite: without the flag (an older daemon) the owner types the code as before', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    await _app(t, await _model(d));
    final dlg = await _inviteAtConfirm(t, d, offered: false);
    expect(find.byKey(const Key('invite-confirm-match')), findsNothing);
    expect(find.byKey(const Key('sas-input')), findsOneWidget);
    expect(find.text(en.pairPeerEnteredCode('Alex')), findsOneWidget);
    await t.enterText(find.byKey(const Key('sas-input')), _code);
    await t.tap(find.byKey(const Key('invite-confirm')));
    await t.pump();
    expect(dlg.inputs.single, isA<ConfirmInput>().having((i) => i.code, 'code', _code));
  });

  testWidgets('invite: code_required brings back the code field with the reason; the typed code is sent', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    await _app(t, await _model(d));
    final dlg = await _inviteAtConfirm(t, d, offered: true);
    await t.tap(find.byKey(const Key('invite-confirm-match')));
    await t.pump();
    dlg.emit(const InputRejected(what: 'confirm', code: XErrorCode.codeRequired, message: 'another invite showed a code'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('invite-confirm-match')), findsNothing);
    expect(find.byKey(const Key('confirm-code-required')), findsOneWidget);
    expect(find.text(en.pairCodeRequired), findsOneWidget);
    expect(find.byKey(const Key('sas-input')), findsOneWidget);
    expect(find.byType(ErrorLine), findsNothing, reason: 'a reason, not an error');
    await t.enterText(find.byKey(const Key('sas-input')), _code);
    await t.tap(find.byKey(const Key('invite-confirm')));
    await t.pump();
    expect(dlg.inputs.last, isA<ConfirmInput>().having((i) => i.yes, 'yes', isTrue).having((i) => i.code, 'code', _code));
    // A wrong code after that is an error as before, and the field stays.
    dlg.emit(const InputRejected(what: 'confirm', code: XErrorCode.sasMismatch, message: 'not the code of this invite'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.textContaining("That's not this invite's code"), findsOneWidget);
    expect(find.byKey(const Key('sas-input')), findsOneWidget);
  });

  testWidgets('invite: bad_request to the click (a daemon older than D-95) falls back to the code field', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    await _app(t, await _model(d));
    final dlg = await _inviteAtConfirm(t, d, offered: true);
    await t.tap(find.byKey(const Key('invite-confirm-match')));
    await t.pump();
    dlg.emit(const InputRejected(what: 'confirm', code: XErrorCode.badRequest, message: 'missing field `code`'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('invite-confirm-match')), findsNothing);
    expect(find.byKey(const Key('sas-input')), findsOneWidget);
    expect(find.text(en.pairPeerEnteredCode('Alex')), findsOneWidget, reason: 'the line that asks for the code');
    expect(find.byKey(const Key('confirm-code-required')), findsNothing);
    expect(find.byType(ErrorLine), findsNothing);
  });

  testWidgets('invite: "Doesn\'t match — decline" next to the button sends "no" without a code', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    await _app(t, await _model(d));
    final dlg = await _inviteAtConfirm(t, d, offered: true);
    await t.tap(find.byKey(const Key('invite-reject')));
    await t.pump();
    expect(dlg.inputs.single, isA<ConfirmInput>().having((i) => i.yes, 'yes', isFalse).having((i) => i.code, 'code', isNull));
  });

  testWidgets('pending invite: one button with the password sends pairing_confirm without a code', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), invites: [_pending(offered: true)]);
    final m = await _model(d);
    await _app(t, m);
    expect(m.invites['inv-31d0']!.confirmWithoutCode, isTrue);
    await _openMonitor(t);
    expect(find.byKey(const Key('monitor-confirm-match')), findsOneWidget);
    expect(find.byKey(const Key('sas-input')), findsNothing);
    expect(find.text(en.pairMonitorPeerEnteredMatch), findsOneWidget);
    // A wrong password: nothing confirmed, still the button.
    await t.enterText(find.byKey(const Key('owner-password')), 'wrong');
    await t.tap(find.byKey(const Key('monitor-confirm-match')));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text(en.errWrongOwnerPassword), findsOneWidget);
    expect(find.byKey(const Key('monitor-confirm-match')), findsOneWidget);

    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('monitor-confirm-match')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.confirmCodes, [null, null], reason: 'never a code the window filled in');
    expect(d.passwords['pairing_confirm'], d.password, reason: 'a trust command keeps its password');
    await _settle(t);
    expect(find.byType(InviteMonitor), findsNothing, reason: 'linked: the dialog closes');
  });

  testWidgets('pending invite: code_required → the code field with the reason; the typed code links', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), invites: [_pending(offered: true)]);
    final m = await _model(d);
    await _app(t, m);
    // Another invite showed a code meanwhile: the daemon no longer accepts the click (the window still shows it).
    d.inviteList = [_pending(offered: false)];
    await _openMonitor(t);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('monitor-confirm-match')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('monitor-code-required')), findsOneWidget);
    expect(find.byKey(const Key('monitor-confirm-match')), findsNothing);
    expect(find.byKey(const Key('sas-input')), findsOneWidget);
    expect(find.byType(ErrorLine), findsNothing);
    await t.enterText(find.byKey(const Key('sas-input')), _code);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('monitor-confirm')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.confirmCodes, [null, _code]);
    await _settle(t);
    expect(find.byType(InviteMonitor), findsNothing);
  });

  testWidgets('pending invite: bad_request (a daemon older than D-95) → the code field', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), invites: [_pending(offered: true)])
      ..pairingWithoutCode = false;
    await _app(t, await _model(d));
    await _openMonitor(t);
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('monitor-confirm-match')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('sas-input')), findsOneWidget);
    expect(find.byKey(const Key('monitor-confirm-match')), findsNothing);
    expect(find.byKey(const Key('monitor-code-required')), findsNothing);
    expect(find.byType(ErrorLine), findsNothing);
  });

  testWidgets('pending invite without the flag: the code field, as before', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), invites: [_pending(offered: false)]);
    await _app(t, await _model(d));
    await _openMonitor(t);
    expect(find.byKey(const Key('monitor-confirm-match')), findsNothing);
    expect(find.byKey(const Key('sas-input')), findsOneWidget);
  });
}
