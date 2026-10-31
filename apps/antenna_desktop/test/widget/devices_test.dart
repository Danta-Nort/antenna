// SPDX-License-Identifier: AGPL-3.0-only
// My devices in the window (x-control/7, CONTROL §27, D-106; experimental), on the fake daemon and a fake Secure
// Enclave: the navigation's counter; what each own computer said (system, Antenna and updates, health, agents,
// requests, a withheld quote); a request answered with one touch over the other computer's challenge and the exact
// text naming the link, the request and its fingerprint; with the password typed here; denied with neither; not
// offered when the other computer accepts no key of this one; keys confirmed with the password; lending; a lost
// computer revoked; an older daemon.

import 'package:antenna_desktop/host/touch_id.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_devices.dart';
import '../support/fake_touch_id.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

Future<(AppModel, FakeDaemon, FakeTouchId)> _setup({
  bool touchId = true,
  bool acceptsMine = true,
  bool lostServer = false,
  bool enabled = true,
}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..devicesEnabled = enabled;
  final h = FakeTouchId(system: touchId);
  final dir = h.dirFor(d.socketPath);
  if (touchId) h.preset(dir, d.ownerKeys);
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, touchId: h);
  await m.connect();
  final key = d.ownerKeys.keys.values.firstOrNull?.keyId ?? '';
  d.devicesState = demoDevices(touchKeyId: key, lostServer: lostServer, acceptsMine: acceptsMine);
  await m.refreshDevices();
  return (m, d, h);
}

Future<void> _open(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await _settle(t);
  await t.tap(_key('nav-devices'));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Finder _key(String k) => find.byKey(Key(k));

/// Scroll the page until [f] is built and on screen (a ListView builds only what it shows).
Future<void> _show(WidgetTester t, Finder f) async {
  await t.scrollUntilVisible(f, 200,
      scrollable: find.ancestor(of: _key('this-computer'), matching: find.byType(Scrollable)).first);
  await _settle(t);
}

const _link = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  testWidgets('the view: this computer, each own computer as it said, the counter of requests', (t) async {
    final (m, _, _) = await _setup();
    await _open(t, m);
    final nav = find.descendant(of: _key('nav-devices'), matching: find.text('2'));
    expect(nav, findsOneWidget, reason: 'two requests wait on the Mac mini');
    expect(find.text(en.navDevices), findsWidgets);
    expect(_key('this-computer'), findsOneWidget);
    expect(find.textContaining('Mayas-MacBook-Pro'), findsOneWidget);
    // The Mac mini: online, its system and version, updates, agents, both requests (one quote withheld)
    expect(_key('device-Mac mini'), findsOneWidget);
    expect(find.textContaining('macOS 27.0 · aarch64'), findsWidgets);
    expect(find.text('64 GB'), findsOneWidget);
    expect(find.textContaining(en.devicesUpdatesAuto), findsWidgets);
    expect(_key('device-agent-Mac mini-codex'), findsOneWidget);
    expect(_key('device-request-k2ab9c1d'), findsOneWidget);
    expect(find.textContaining('The refactor of the payments module'), findsOneWidget);
    expect(_key('device-request-withheld-p7xq2m4n'), findsOneWidget, reason: 'a secret never travels');
    // The build server: a problem, a key offered, lends itself
    await _show(t, find.text(en.devicesHealthRelayUnreachable(2)));
    expect(find.text(en.devicesHealthRelayUnreachable(2)), findsOneWidget);
    expect(_key('device-confirm-build server'), findsOneWidget);
    expect(find.text(en.devicesLends), findsOneWidget);
    expect(find.textContaining(en.devicesUpdateStaged('0.2.1')), findsOneWidget);
  });

  /// Negative control (run once, 2026-10-06): with the request's ID signed as its fingerprint in
  /// `deviceApproveWithTouchId`, the fake refused the proof (`proof_invalid`) and the approval stayed.
  testWidgets('approve with one touch: the other computer\'s challenge, then the exact text it checks', (t) async {
    final (m, d, h) = await _setup();
    await _open(t, m);
    expect(h.prompts, isEmpty, reason: 'no prompt without a click');
    await t.tap(_key('device-approve-touchid-k2ab9c1d'));
    await _settle(t);
    final text = remoteApproveText(linkId: _link, id: 'k2ab9c1d', fingerprint: '9c41e07a3b5d0f12');
    expect(d.deviceDecisions, [('Mac mini', text, 'touch_id')]);
    expect(h.prompts.single.reason, en.devicesTouchReason('Mac mini', en.actionSendMessage));
    expect(h.prompts.single.request, text, reason: 'the touch signs the text that travels');
    expect(d.calls.where((c) => c.startsWith('device_')), ['device_challenge', 'device_approve']);
    expect(_key('device-request-k2ab9c1d'), findsNothing, reason: 'decided there, gone here');
    expect(find.descendant(of: _key('nav-devices'), matching: find.text('1')), findsOneWidget);
  });

  testWidgets('approve with the password typed here; deny with neither', (t) async {
    final (m, d, _) = await _setup(touchId: false);
    await _open(t, m);
    expect(_key('device-approve-touchid-k2ab9c1d'), findsNothing, reason: 'no Touch ID on this computer');
    await t.tap(_key('device-approve-k2ab9c1d'));
    await _settle(t);
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('password-ok'));
    await _settle(t);
    expect(d.deviceDecisions.single, ('Mac mini', 'k2ab9c1d approve 9c41e07a3b5d0f12', 'password'));
    await t.tap(_key('device-deny-p7xq2m4n'));
    await _settle(t);
    expect(d.deviceDecisions.last, ('Mac mini', 'p7xq2m4n deny', 'password'));
    expect(d.passwords, isEmpty, reason: 'the fake records local owner passwords only');
  });

  testWidgets('a computer that accepts no key of this one: no approve, a pointer, deny still works', (t) async {
    final (m, d, _) = await _setup(acceptsMine: false);
    await _open(t, m);
    expect(_key('device-request-cannot-k2ab9c1d'), findsOneWidget);
    expect(_key('device-approve-touchid-k2ab9c1d'), findsNothing);
    expect(_key('device-approve-k2ab9c1d'), findsNothing);
    expect(find.text(en.devicesCannotApprove('Mac mini')), findsWidgets);
    await t.tap(_key('device-deny-k2ab9c1d'));
    await _settle(t);
    expect(d.deviceDecisions.single.$3, 'password');
  });

  testWidgets('the other computer refuses: its reason is shown and the request stays', (t) async {
    final (m, d, _) = await _setup();
    d.deviceRefusal = const XControlException(XErrorCode.ownerKeyUnknown, 'the other computer has not confirmed this key');
    await _open(t, m);
    await t.tap(_key('device-approve-touchid-k2ab9c1d'));
    await _settle(t);
    expect(d.deviceDecisions, isEmpty);
    expect(_key('device-request-k2ab9c1d'), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.textContaining('confirmed'), findsWidgets);
  });

  testWidgets('a Touch ID sheet the owner closes says nothing and approves nothing', (t) async {
    final (m, d, h) = await _setup();
    h.nextFailure = TouchIdFailure.cancelled;
    await _open(t, m);
    await t.tap(_key('device-approve-touchid-k2ab9c1d'));
    await _settle(t);
    expect(d.deviceDecisions, isEmpty);
    expect(_key('device-request-k2ab9c1d'), findsOneWidget);
  });

  testWidgets('accept approvals from a computer: its offered keys, with the password', (t) async {
    final (m, d, _) = await _setup(touchId: false);
    await _open(t, m);
    await _show(t, _key('device-confirm-build server'));
    await t.tap(_key('device-confirm-build server'));
    await _settle(t);
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('password-ok'));
    await _settle(t);
    expect(d.deviceConfirms.single.$1, 'build server');
    expect(d.deviceConfirms.single.$2, ['5e1f0a2b3c4d5e6f']);
    expect(_key('device-confirm-build server'), findsNothing, reason: 'nothing offered any more');
    expect(find.text(en.devicesAccepts('build server', en.devicesKeyPassword)), findsOneWidget);
  });

  testWidgets('lend this computer: on with the password, off without', (t) async {
    final (m, d, _) = await _setup(touchId: false);
    await _open(t, m);
    expect(t.widget<Switch>(_key('device-lend')).value, isFalse);
    await t.tap(_key('device-lend'));
    await _settle(t);
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('password-ok'));
    await _settle(t);
    expect(d.lendCalls.single, (true, d.password));
    expect(t.widget<Switch>(_key('device-lend')).value, isTrue);
    await t.tap(_key('device-lend'));
    await _settle(t);
    expect(d.lendCalls.last, (false, null));
  });

  testWidgets('a lost computer: the banner, then revoke with the password; the card goes', (t) async {
    final (m, d, _) = await _setup(lostServer: true, touchId: false);
    await _open(t, m);
    await _show(t, _key('device-lost-revoke-build server'));
    expect(_key('device-lost-build server'), findsOneWidget);
    expect(find.textContaining('Mac mini reported this computer as lost'), findsOneWidget);
    await t.tap(_key('device-lost-revoke-build server'));
    await _settle(t);
    expect(_key('device-revoke-dialog'), findsOneWidget);
    expect(find.text(en.devicesRevokeContacts('build server')), findsOneWidget, reason: 'the honest limit is said');
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('device-revoke-confirm'));
    await _settle(t);
    expect(d.deviceRevokes, ['build server']);
    expect(_key('device-revoke-dialog'), findsNothing);
    expect(_key('device-build server'), findsNothing);
  });

  // D-131: with Touch ID on, the same three take one touch here instead of the password.
  testWidgets('with Touch ID on: lending and accepting keys each take one touch', (t) async {
    final (m, d, h) = await _setup();
    await _open(t, m);
    await t.tap(_key('device-lend'));
    await _settle(t);
    expect(_key('password-ok'), findsNothing);
    expect(d.lendCalls.single, (true, ''));
    await _show(t, _key('device-confirm-build server'));
    await t.tap(_key('device-confirm-build server'));
    await _settle(t);
    expect(_key('password-ok'), findsNothing);
    expect(d.deviceConfirms.single.$1, 'build server');
    expect(d.proven, ['device_lend_set', 'device_keys_confirm']);
    expect(h.shown, 2, reason: 'one touch each');
  });

  testWidgets('with Touch ID on: revoking a lost computer takes one touch', (t) async {
    final (m, d, h) = await _setup(lostServer: true);
    await _open(t, m);
    await _show(t, _key('device-lost-revoke-build server'));
    await t.tap(_key('device-lost-revoke-build server'));
    await _settle(t);
    expect(_key('owner-touch'), findsOneWidget);
    expect(_key('owner-password'), findsNothing);
    await t.tap(_key('device-revoke-confirm'));
    await _settle(t);
    expect(d.deviceRevokes, ['build server']);
    expect(d.proven, ['device_revoke']);
    expect(h.prompts.single.request, contains('"cmd":"device_revoke"'));
  });

  testWidgets('a daemon before own devices: the page says so and asks for nothing', (t) async {
    final (m, d, _) = await _setup(enabled: false);
    await _open(t, m);
    expect(find.text(en.devicesAbsent), findsOneWidget);
    expect(_key('this-computer'), findsNothing);
    expect(d.deviceDecisions, isEmpty);
  });
}
