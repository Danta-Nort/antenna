// SPDX-License-Identifier: AGPL-3.0-only
// Touch ID for owner commands in the window (D-102, CONTROL §22), on the fake daemon and a fake Secure Enclave:
// enrolling with the password and one touch; one touch per approval and per listed batch, the signed request carrying
// what the owner was shown; unlocking and signing in with one touch; and every way back to the password (cancelled,
// unavailable, the password due, the key gone from the daemon, fingerprints changed), with nothing shown on Linux or
// with an older daemon, and no prompt without a click.

import 'dart:async';
import 'dart:convert';

import 'package:antenna_desktop/host/touch_id.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/approvals/approvals_view.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:antenna_desktop/ui/security/touch_id_text.dart';
import 'package:antenna_desktop/ui/settings/touch_id_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_owner_keys.dart';
import '../support/fake_touch_id.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

Future<(AppModel, FakeDaemon, FakeTouchId)> _setup({
  bool enrolled = true,
  DaemonState state = DaemonState.unlocked,
  bool session = true,
  int proto = 7,
  List<ApprovalInfo>? approvals,
  TouchIdHost? host,
  bool atStart = false,
}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: approvals, state: state)
    ..protoVersion = proto;
  if (!session) d.sessionToken = null;
  final h = FakeTouchId();
  if (enrolled) h.preset(h.dirFor(d.socketPath), d.ownerKeys);
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, touchId: host ?? h);
  await m.connect();
  // The gate as after "Lock keys" (a click starts Touch ID); [atStart]: as when the app opens (D-131).
  m.touchIdAtStart = atStart;
  return (m, d, h);
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _security(WidgetTester t) async {
  await t.tap(find.byKey(const Key('nav-settings')));
  await _settle(t);
  await t.tap(find.byKey(const Key('settings-security')));
  await _settle(t);
}

Finder _key(String k) => find.byKey(Key(k));

/// Three requests from one agent in Emily's conversation.
List<ApprovalInfo> _three() => [
      agentApproval('ap-1', emily, fingerprint: 'f1f1f1f1', quote: 'one', minutesAgo: 3),
      agentApproval('ap-2', emily, fingerprint: 'f2f2f2f2', quote: 'two', minutesAgo: 2),
      agentApproval('ap-3', emily, fingerprint: 'f3f3f3f3', quote: 'three', minutesAgo: 1),
    ];

void main() {
  testWidgets('enroll: the password, one touch named for it, the slot sealed, the key ID recorded', (t) async {
    final (m, d, h) = await _setup(enrolled: false);
    await _app(t, m);
    await _security(t);
    expect(_key('touchid-switch'), findsOneWidget);
    expect(t.widget<Switch>(_key('touchid-switch')).value, isFalse);
    await t.tap(_key('touchid-switch'));
    await _settle(t);
    expect(find.byType(TouchIdEnrollDialog), findsOneWidget);
    expect(find.text(en.touchIdEnrollPassword), findsOneWidget, reason: 'the dialog says when the password stays');
    expect(find.text(en.touchIdEnrollWarning), findsOneWidget, reason: 'refuse a prompt that appears by itself');
    expect(h.prompts, isEmpty, reason: 'no touch before the password');
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('touchid-enroll'));
    await _settle(t);

    expect(d.passwords['owner_key_add'], d.password, reason: 'enrolling always takes the password');
    expect(d.ownerKeys.challengeKinds, [true], reason: 'an enroll challenge, for owner_key_add only');
    final key = d.ownerKeys.keys.values.single;
    final dir = h.dirFor(d.socketPath);
    expect(key.publicKey, h.publicKeyOf(dir), reason: 'the new Secure Enclave key, with a proof by itself');
    expect(h.prompts.single.reason, en.touchIdReasonEnroll);
    expect(h.slotOf(dir), key.slotKey, reason: 'the slot key sealed here');
    expect((m.ownerKeyRecord?.keyId, m.ownerKeyRecord?.unlock), (key.keyId, true));
    expect(jsonDecode(d.ownerKeys.lines.single.$1), {
      'cmd': 'owner_key_add',
      'public_key': key.publicKey,
      'label': startsWith('touchid@'),
      'unlock': true,
      'password': d.password,
    });
    expect(find.byType(TouchIdEnrollDialog), findsNothing, reason: 'the dialog closed');
    expect(t.widget<Switch>(_key('touchid-switch')).value, isTrue);
    expect(m.touchIdReady && m.touchIdUnlockReady, isTrue);
  });

  /// Negative control (seen failing): enrolling with a plain challenge; the daemon answered `password_required`.
  testWidgets('enroll while the password is due: the enroll challenge, no other password command', (t) async {
    final (m, d, h) = await _setup(enrolled: false);
    d.ownerKeys
      ..passwordDueMs = ms(ago(days: 1))
      ..needPassword = true;
    await _app(t, m);
    await _security(t);
    await t.tap(_key('touchid-switch'));
    await _settle(t);
    await t.enterText(_key('owner-password'), d.password);
    final before = d.calls.length;
    await t.tap(_key('touchid-enroll'));
    await _settle(t);
    expect(d.ownerKeys.keys, hasLength(1));
    expect(m.touchIdOn, isTrue);
    expect(d.calls.sublist(before).where((c) => c != 'owner_key_list'), ['owner_challenge', 'owner_key_add'],
        reason: 'the enroll challenge, then the enrollment; no other command spends the password');
    expect(d.passwords.keys, ['owner_key_add']);
    expect(h.shown, 1);
  });

  testWidgets('enroll without HPKE (macOS 12–13): no unlock slot, unlocking keeps the password', (t) async {
    final (m, d, h) = await _setup(enrolled: false);
    h.hpke = false;
    await m.refreshTouchId();
    await _app(t, m);
    await _security(t);
    await t.tap(_key('touchid-switch'));
    await _settle(t);
    expect(find.text(en.touchIdEnrollNoHpke), findsOneWidget);
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('touchid-enroll'));
    await _settle(t);
    expect(jsonDecode(d.ownerKeys.lines.single.$1)['unlock'], false);
    expect((m.touchIdReady, m.touchIdUnlockReady), (true, false));
    expect(find.text(en.touchIdNoUnlock), findsOneWidget);
  });

  testWidgets('a wrong password enrolls nothing and leaves no key here', (t) async {
    final (m, d, h) = await _setup(enrolled: false);
    await _app(t, m);
    await _security(t);
    await t.tap(_key('touchid-switch'));
    await _settle(t);
    await t.enterText(_key('owner-password'), 'not the password');
    await t.tap(_key('touchid-enroll'));
    await _settle(t);
    expect(find.text(en.errWrongPassword), findsOneWidget);
    expect(d.ownerKeys.keys, isEmpty);
    expect(h.publicKeyOf(h.dirFor(d.socketPath)), isNull, reason: 'the unenrolled Secure Enclave key is removed');
    expect(m.ownerKeyRecord, isNull);
  });

  testWidgets('turning it off removes the key from the daemon and this Mac, no password', (t) async {
    final (m, d, h) = await _setup();
    await _app(t, m);
    await _security(t);
    expect(t.widget<Switch>(_key('touchid-switch')).value, isTrue);
    await t.tap(_key('touchid-switch'));
    await _settle(t);
    expect(_key('owner-password'), findsNothing);
    expect(d.calls, contains('owner_key_remove'));
    expect(d.ownerKeys.keys, isEmpty);
    expect(h.publicKeyOf(h.dirFor(d.socketPath)), isNull);
    expect(t.widget<Switch>(_key('touchid-switch')).value, isFalse);
  });

  testWidgets('the "?" says when the password is asked next', (t) async {
    final (m, d, _) = await _setup();
    d.ownerKeys.passwordDueMs = ms(DateTime(2026, 10, 16, 9));
    await _app(t, m);
    await _security(t);
    expect(find.byKey(const Key('touchid-due')), findsNothing, reason: 'behind the "?" only');
    await t.tap(_key('help-touchid'));
    await _settle(t);
    expect(find.text(en.touchIdPasswordDue('Oct 16, 2026')), findsOneWidget);
    expect(find.text(en.touchIdSettingHint), findsOneWidget);
  });

  /// Negative control (seen failing): `approveWithTouchId` sent `approve` without `fingerprint`; the signed text then
  /// did not name what the owner was shown.
  testWidgets('approve with one touch: the signed request carries the ID and the fingerprint shown', (t) async {
    final a = demoChatApproval();
    final (m, d, h) = await _setup(approvals: [a]);
    await m.select(emily.linkId);
    await _app(t, m);
    expect(_key('approve-${a.id}'), findsNothing, reason: 'Touch ID is the primary action');
    expect(_key('approve-password-${a.id}'), findsOneWidget, reason: 'the password stays reachable');
    expect(h.prompts, isEmpty);
    await t.tap(_key('approve-touchid-${a.id}'));
    await _settle(t);
    expect(_key('owner-password'), findsNothing);
    expect(d.ownerKeys.lines.single.$1, '{"cmd":"approve","id":"${a.id}","password":"","fingerprint":"${a.fingerprint}"}');
    expect(h.prompts.single.reason, en.touchIdReasonShareFile(emily.label));
    expect(h.prompts.single.request, d.ownerKeys.lines.single.$1, reason: 'the touch signed exactly the sent text');
    expect(m.approvals, isEmpty);
    expect(d.passwords.keys, isNot(contains('approve')));
    expect(d.ownerKeys.challengeKinds, [false], reason: 'an approval never asks for an enroll challenge');
  });

  testWidgets('"Use password" keeps the password flow', (t) async {
    final a = demoChatApproval();
    final (m, d, h) = await _setup(approvals: [a]);
    await m.select(emily.linkId);
    await _app(t, m);
    await t.tap(_key('approve-password-${a.id}'));
    await _settle(t);
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('password-ok'));
    await _settle(t);
    expect(d.passwords['approve'], d.password);
    expect(h.prompts, isEmpty);
    expect(m.approvals, isEmpty);
  });

  testWidgets('cancelled: the password field opens, and the password approves', (t) async {
    final a = demoChatApproval();
    final (m, d, h) = await _setup(approvals: [a]);
    h.nextFailure = TouchIdFailure.cancelled;
    await m.select(emily.linkId);
    await _app(t, m);
    await t.tap(_key('approve-touchid-${a.id}'));
    await _settle(t);
    expect(_key('owner-password'), findsOneWidget);
    expect(_key('password-note'), findsNothing, reason: 'nothing to explain after a cancel');
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('password-ok'));
    await _settle(t);
    expect(d.passwords['approve'], d.password);
    expect(m.approvals, isEmpty);
    expect(m.touchIdReady, isTrue, reason: 'a cancel does not turn Touch ID off');
  });

  testWidgets('unavailable: no Touch ID button; unavailable in the middle: the password with the reason', (t) async {
    final a = demoChatApproval();
    final (m, d, h) = await _setup(approvals: [a]);
    h.available = false;
    await m.refreshTouchId();
    await m.select(emily.linkId);
    await _app(t, m);
    expect(_key('approve-touchid-${a.id}'), findsNothing);
    expect(_key('approve-${a.id}'), findsOneWidget);

    // The lid closes after the window checked: the prompt cannot show, the password says why.
    h.available = true;
    await m.refreshTouchId();
    await _settle(t);
    h.available = false;
    await t.tap(_key('approve-touchid-${a.id}'));
    await _settle(t);
    expect(find.text(en.touchIdNoteUnavailable), findsOneWidget);
    await t.tap(find.text(en.commonCancel));
    await _settle(t);
    expect(_key('approve-${a.id}'), findsOneWidget, reason: 'the password until the next check');
  });

  /// Negative control (seen failing): `approveManyWithTouchId` sent the items without their fingerprints.
  testWidgets('batch: one touch, one approve_many naming every request and its fingerprint', (t) async {
    final (m, d, h) = await _setup(approvals: _three());
    await m.select(emily.linkId);
    await _app(t, m);
    await t.tap(_key('approve-all-builder'));
    await _settle(t);
    expect(_key('owner-password'), findsNothing);
    expect(h.shown, 1, reason: 'one touch for the listed batch');
    expect(h.prompts.single.reason, en.touchIdReasonMany(3, 'builder'));
    expect(d.ownerKeys.lines.single.$1,
        '{"cmd":"approve_many","items":[{"id":"ap-1","fingerprint":"f1f1f1f1"},{"id":"ap-2","fingerprint":"f2f2f2f2"},'
        '{"id":"ap-3","fingerprint":"f3f3f3f3"}],"password":""}');
    expect([for (final i in d.approveManyCalls.single.$1) i.id], ['ap-1', 'ap-2', 'ap-3']);
    expect(m.approvals, isEmpty);
  });

  testWidgets('the list: "Approve selected" with one touch', (t) async {
    final (m, d, h) = await _setup(approvals: _three());
    await _app(t, m);
    unawaited(showApprovalsDialog(t.element(find.byType(HomeScreen))));
    await _settle(t);
    await t.tap(_key('approvals-select-all'));
    await t.pump();
    await t.ensureVisible(_key('approve-selected'));
    await t.tap(_key('approve-selected'));
    await _settle(t);
    expect(_key('owner-password'), findsNothing);
    expect(h.shown, 1);
    expect(jsonDecode(d.ownerKeys.lines.single.$1)['items'], hasLength(3));
    expect(m.approvals, isEmpty);
  });

  /// Negative control (seen failing): `_withTouch` signed before it asked for the challenge; a Touch ID prompt then
  /// appeared although the daemon wanted the password anyway.
  testWidgets('password_required: no Touch ID prompt, the password field says why (14 days)', (t) async {
    final a = demoChatApproval();
    final (m, d, h) = await _setup(approvals: [a]);
    d.ownerKeys
      ..passwordDueMs = ms(ago(days: 1))
      ..needPassword = true;
    await m.refreshOwnerKeys();
    await m.select(emily.linkId);
    await _app(t, m);
    await t.tap(_key('approve-touchid-${a.id}'));
    await _settle(t);
    expect(h.prompts, isEmpty, reason: 'the challenge said so before any prompt');
    expect(find.text(en.touchIdNoteDue), findsOneWidget);
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('password-ok'));
    await _settle(t);
    expect(d.passwords['approve'], d.password);
    expect(d.ownerKeys.needPassword, isFalse, reason: 'the password resets the clock');
  });

  testWidgets('password_required after failed attempts: the password field says so', (t) async {
    final a = demoChatApproval();
    final (m, d, _) = await _setup(approvals: [a]);
    d.ownerKeys.failedProofs = 3;
    await m.refreshOwnerKeys();
    await m.select(emily.linkId);
    await _app(t, m);
    await t.tap(_key('approve-touchid-${a.id}'));
    await _settle(t);
    expect(find.text(en.touchIdNoteFailed), findsOneWidget);
  });

  testWidgets('owner_key_unknown: the key is dropped here, Touch ID off, the password', (t) async {
    final a = demoChatApproval();
    final (m, d, h) = await _setup(approvals: [a]);
    d.ownerKeys.keys.clear(); // removed with the CLI, or another window
    await m.select(emily.linkId);
    await _app(t, m);
    await t.tap(_key('approve-touchid-${a.id}'));
    await _settle(t);
    expect(find.text(en.touchIdNoteKeyGone), findsOneWidget);
    expect(m.ownerKeyRecord, isNull);
    expect(h.publicKeyOf(h.dirFor(d.socketPath)), isNull, reason: 'the local key goes too');
    await t.tap(find.text(en.commonCancel));
    await _settle(t);
    expect(_key('approve-${a.id}'), findsOneWidget);
    expect(_key('approve-touchid-${a.id}'), findsNothing);
  });

  testWidgets('fingerprints changed: the password now, Settings says to turn Touch ID on again', (t) async {
    final a = demoChatApproval();
    final (m, d, h) = await _setup(approvals: [a]);
    await m.select(emily.linkId);
    await _app(t, m);
    h.domainChanged = true; // a finger added after enrolling: the key is dead (.biometryCurrentSet)
    await t.tap(_key('approve-touchid-${a.id}'));
    await _settle(t);
    expect(find.text(en.touchIdNoteFingerprints), findsOneWidget);
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('password-ok'));
    await _settle(t);
    expect(d.passwords['approve'], d.password, reason: 'the password for this action');
    await _security(t);
    expect(find.text(en.touchIdFingerprintsChanged), findsOneWidget);
    expect(t.widget<Switch>(_key('touchid-switch')).value, isFalse);

    // Turning it on again removes the dead key and enrolls a new one with the password.
    h.domainChanged = false;
    final dead = m.ownerKeyRecord!.keyId;
    await t.tap(_key('touchid-switch'));
    await _settle(t);
    await t.enterText(_key('owner-password'), d.password);
    await t.tap(_key('touchid-enroll'));
    await _settle(t);
    expect(d.ownerKeys.keys.keys, isNot(contains(dead)));
    expect(d.ownerKeys.keys, hasLength(1));
    expect(m.touchIdReady, isTrue);
  });

  /// After "Lock keys" (not at app start). Negative control (seen failing): the gate started the Touch ID unlock by
  /// itself when it was built.
  testWidgets('unlock: no prompt before the click; one touch opens the slot, unlocks and signs in', (t) async {
    final (m, d, h) = await _setup(state: DaemonState.locked);
    expect(m.phase, Phase.locked);
    await _app(t, m);
    await t.pump(const Duration(seconds: 1));
    expect(h.prompts, isEmpty, reason: 'a Touch ID prompt only after the owner clicks');
    expect(_key('password'), findsOneWidget, reason: 'the password field stays under it');
    await t.tap(_key('touchid-unlock'));
    await _settle(t);
    expect(m.phase, Phase.unlocked);
    expect(h.shown, 1, reason: 'one touch for unlock and sign-in');
    expect([for (final p in h.prompts) (p.method, p.reuse)], [('openSlot', false), ('sign', true)]);
    expect(h.prompts.first.reason, en.touchIdReasonUnlock);
    expect(d.ownerKeys.lines.single.$1, '{"cmd":"login","password":"","hold":true}');
    expect(m.daemon.sessionToken, 'xos_fake');
  });

  testWidgets('unlock cancelled: the password field gets the focus', (t) async {
    final (m, _, h) = await _setup(state: DaemonState.locked);
    h.nextFailure = TouchIdFailure.cancelled;
    await _app(t, m);
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();
    await t.tap(_key('touchid-unlock'));
    await _settle(t);
    expect(m.phase, Phase.locked);
    expect(t.widget<TextField>(_key('password')).focusNode!.hasFocus, isTrue);
  });

  testWidgets('unlock when the password is due: the keys stay locked, the gate says why', (t) async {
    final (m, d, h) = await _setup(state: DaemonState.locked);
    d.ownerKeys.needPassword = true;
    await _app(t, m);
    await t.tap(_key('touchid-unlock'));
    await _settle(t);
    expect(m.phase, Phase.locked);
    expect(find.text(en.touchIdNoteRequired), findsOneWidget);
    await t.enterText(_key('password'), d.password);
    await t.tap(_key('submit'));
    await _settle(t);
    expect(m.phase, Phase.unlocked);
    expect(h.shown, 1);
  });

  testWidgets('sign in with Touch ID: the keys are unlocked, one touch opens the session', (t) async {
    final (m, d, h) = await _setup(session: false);
    expect(m.phase, Phase.loginRequired);
    await _app(t, m);
    expect(_key('touchid-unlock'), findsNothing);
    await t.tap(_key('touchid-signin'));
    await _settle(t);
    expect(m.phase, Phase.unlocked);
    expect(h.prompts.single.reason, en.touchIdReasonSignIn);
    expect(h.prompts.single.reuse, isFalse);
    expect(d.ownerKeys.lines.single.$1, '{"cmd":"login","password":"","hold":true}');
  });

  /// A fix with its test: the touch was made inside the session dialog, and a touch slower than the window's 15 s
  /// wait for the session event left the window signed out (seen failing before the fix).
  testWidgets('sign in with a slow touch: the session is opened after the touch, however long it took', (t) async {
    final (m, _, h) = await _setup(session: false);
    h.touchTakes = const Duration(seconds: 25);
    await _app(t, m);
    await t.tap(_key('touchid-signin'));
    await t.pump(const Duration(seconds: 26));
    await _settle(t);
    expect(m.phase, Phase.unlocked);
  });

  /// Negative control (seen failing): every `touchIdHost.supported` check of TouchIdMixin replaced by `true` (with
  /// only the getters' checks gone the test still passes: `refreshTouchId` reads nothing on such a system).
  testWidgets('Linux: no Touch ID anywhere, even with a daemon that has owner keys', (t) async {
    // A host that would report Touch ID if asked, on a system that has none.
    final linux = FakeTouchId(system: false);
    final a = demoChatApproval();
    final (m, d, _) = await _setup(enrolled: false, approvals: [a], host: linux);
    linux.preset(linux.dirFor(d.socketPath), d.ownerKeys);
    await m.refreshTouchId();
    await m.select(emily.linkId);
    await _app(t, m);
    expect(_key('approve-touchid-${a.id}'), findsNothing);
    expect(_key('approve-password-${a.id}'), findsNothing);
    expect(_key('approve-${a.id}'), findsOneWidget);
    await _security(t);
    expect(_key('touchid-card'), findsNothing);
    expect(_key('touchid-switch'), findsNothing);
    await m.lock();
    await _settle(t);
    expect(_key('touchid-unlock'), findsNothing);
    expect(linux.prompts, isEmpty);
  });

  testWidgets('a daemon older than x-control/7: no Touch ID, even with a key here', (t) async {
    final a = demoChatApproval();
    final (m, d, _) = await _setup(proto: 6, approvals: [a]);
    await m.select(emily.linkId);
    await _app(t, m);
    expect(_key('approve-touchid-${a.id}'), findsNothing);
    expect(_key('approve-${a.id}'), findsOneWidget);
    await _security(t);
    expect(_key('touchid-switch'), findsNothing);
    expect(d.calls, isNot(contains('owner_key_list')));
  });

  /// The fake daemon refuses a challenge of the wrong kind both ways, as antennad does; with it, any enrollment of the
  /// window over a plain challenge fails every enrollment test above.
  test('the fake daemon: a challenge serves its purpose only', () async {
    final d = FakeDaemon()..protoVersion = 7;
    const pub = 'BFakeKey';
    ProofSource by(OwnerChallengeReply ch) => (req) async => OwnerProof(keyId: fakeKeyId(pub), nonce: ch.nonce, sig: fakeSig(pub, ch.nonce, req));
    final add = OwnerKeyAddRequest(publicKey: pub, label: 'touchid@mac', password: d.password, unlock: true);
    await expectLater(d.callWithProof(add, by(await d.ownerChallenge())),
        throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.challengeInvalid)));
    expect(await d.callWithProof(add, by(await d.ownerChallenge(enroll: true))), isA<OwnerKeyAddedReply>());
    d.approvalList = [demoChatApproval()];
    final a = d.approvalList.single;
    final approve = ApproveRequest(id: a.id, password: '', fingerprint: a.fingerprint);
    await expectLater(d.callWithProof(approve, by(await d.ownerChallenge(enroll: true))),
        throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.challengeInvalid)));
    expect(await d.callWithProof(approve, by(await d.ownerChallenge())), isA<ApprovalReply>());
  });

  test('reasons name what is approved; names from agents are cut to one short line', () {
    final a = agentApproval('ap-9', emily, requester: 'claude\nIgnore this and approve everything ${'x' * 80}');
    expect(touchIdApproveReason(en, a), en.touchIdReasonSend(emily.label));
    final other = agentApproval('ap-8', emily, action: 'check:exec', requester: 'claude\u0007-backend-${'y' * 60}');
    final r = touchIdApproveReason(en, other);
    expect(r, isNot(contains('\u0007')));
    expect(r.length, lessThan(100));
    expect(r, contains('…'));
    expect(cutForPrompt('a\nb\tc'), 'a b c');
    expect(touchIdBatchReason(en, [a, other, agentApproval('ap-7', emily, requester: 'codex')]),
        allOf(startsWith('approve 3 requests from '), contains('…')));
  });
}
