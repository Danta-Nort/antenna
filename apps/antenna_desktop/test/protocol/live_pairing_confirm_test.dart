// SPDX-License-Identifier: AGPL-3.0-only
// Pairing confirmation with one button (D-95) against REAL `antennad` daemons: once the joiner entered the code, the
// daemon offers `confirm_without_code` and the window's invite state confirms with the owner's click (no code); an
// invite created without a follow connection is confirmed with `pairing_confirm` and the password, without the code;
// with two invites showing codes at once (formal model F-4) the daemon does not offer it and refuses a confirmation
// without the code with `code_required`, and the typed code still links.
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_pairing_confirm_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/pairing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Matcher _code(String c) => isA<XControlException>().having((e) => e.code, 'code', c);

/// Wait until [done] holds, checking every 50 ms (the daemons work in real time).
Future<void> _until(FutureOr<bool> Function() done, {Duration timeout = const Duration(seconds: 20)}) async {
  final sw = Stopwatch()..start();
  while (!await done()) {
    if (sw.elapsed > timeout) throw TimeoutException('condition not reached in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final antennad = findXd();
  late Directory root;
  late XdNode alice;
  late XdNode bob;
  late XdNode carol;
  late XControlClient a;
  late XControlClient b;
  late XControlClient c;

  setUpAll(() async {
    if (antennad == null) return;
    root = await tempRoot();
    alice = XdNode('alice', root, antennad);
    bob = XdNode('bob', root, antennad);
    carol = XdNode('carol', root, antennad);
    await Future.wait([alice.start(), bob.start(), carol.start()]);
    a = XControlClient(alice.socket);
    b = XControlClient(bob.socket);
    c = XControlClient(carol.socket);
    await Future.wait([a.init(alice.password), b.init(bob.password), c.init(carol.password)]);
    await Future.wait([
      openOwnerSession(a, alice.password),
      openOwnerSession(b, bob.password),
      openOwnerSession(c, carol.password),
    ]);
  });

  tearDownAll(() async {
    if (antennad == null) return;
    await Future.wait([alice.stop(), bob.stop(), carol.stop()]);
    await root.delete(recursive: true);
  });

  test('two invites with codes at once (F-4): no offer, code_required, the typed code links', () async {
    // First, so that the later tests start with no other invite of alice's showing a code.
    final inv1 = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'bob', password: alice.password)));
    final inv2 = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'carol', password: alice.password)));
    final created1 = await inv1.next<InviteCreated>();
    final created2 = await inv2.next<InviteCreated>();
    final j1 = Events(b.open(JoinRequest(
        link: created1.link, trust: 3, label: 'alice', connectTimeoutMs: 5000, password: bob.password)));
    final j2 = Events(c.open(JoinRequest(
        link: created2.link, trust: 3, label: 'alice', connectTimeoutMs: 5000, password: carol.password)));
    final sas1 = await inv1.next<SasEvent>();
    await inv2.next<SasEvent>();
    await j2.next<NeedInput>((e) => e.isSasCode);
    // Carol walks away; her invite did show its code while Bob's was open.
    await j2.close();
    await j1.next<NeedInput>((e) => e.isSasCode);
    j1.dialog.input(SasCodeInput(sas1.code));
    final need = await inv1.next<NeedInput>((e) => e.isConfirm);
    expect(need.confirmWithoutCode, isFalse, reason: 'a spoken "it matches" may be about either invite');
    final listed = (await a.pairings()).singleWhere((i) => i.id == created1.id);
    expect(listed.needsConfirm, isTrue);
    expect(listed.confirmWithoutCode, isFalse);
    // Both ways of confirming without the code are refused with code_required; the invite stays alive.
    await expectLater(a.pairingConfirm(created1.id!, alice.password), throwsA(_code(XErrorCode.codeRequired)));
    inv1.dialog.input(const ConfirmInput(true));
    final rej = await inv1.next<InputRejected>();
    expect((rej.what, rej.code), ('confirm', XErrorCode.codeRequired));
    expect(await a.contacts(), isEmpty);
    // The code the owner read out, typed: linked.
    inv1.dialog.input(ConfirmInput(true, code: sas1.code));
    final ra = await inv1.dialog.result as LinkedReply;
    final rb = await j1.dialog.result as LinkedReply;
    expect(ra.linkId, rb.linkId);
    await inv2.close();
    // Burn Carol's invite, if her refusal did not end it already.
    try {
      await a.pairingCancel(created2.id!, alice.password);
    } on XControlException {
      // Already finished.
    }
    print('F-4: confirm_without_code absent; pairing_confirm and "yes" without a code → code_required; typed → linked');
  }, skip: antennad == null ? noXdReason : false);

  test('the window\'s invite state: the daemon offers the button, the click links without a code', () async {
    final s = InviteSession(
      a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'carol', password: alice.password)),
      trust: 3,
      ttl: const Duration(minutes: 2),
      label: 'carol',
    );
    addTearDown(s.dispose);
    await _until(() => s.link != null);
    final join = Events(c.open(JoinRequest(
        link: s.link!, trust: 3, label: 'alice', connectTimeoutMs: 5000, password: carol.password)));
    await join.next<NeedInput>((e) => e.isSasCode);
    await _until(() => s.sas != null);
    join.dialog.input(SasCodeInput(s.sas!));
    await _until(() => s.phase == InvitePhase.needConfirm);
    expect(s.confirmWithoutCode, isTrue, reason: 'need_input confirm carries confirm_without_code');
    expect(s.confirmByButton, isTrue);
    final listed = (await a.pairings()).singleWhere((i) => i.id == s.inviteId);
    expect(listed.confirmWithoutCode, isTrue, reason: '`pairings` says it too');
    s.confirmMatch();
    await _until(() => s.finished);
    expect(s.phase, InvitePhase.linked, reason: '${s.error}');
    final rc = await join.dialog.result as LinkedReply;
    expect(s.linked!.linkId, rc.linkId);
    expect((await a.contacts()).map((x) => x.label), contains('carol'));
    print('BUTTON: need_input confirm_without_code → "yes" without a code → linked (${s.linked!.pairingMs} ms)');
  }, skip: antennad == null ? noXdReason : false);

  test('an invite without a follow connection: pairing_confirm with the password and no code', () async {
    // A third node for a fresh link.
    final dave = XdNode('dave', root, antennad!);
    await dave.start();
    addTearDown(dave.stop);
    final d = XControlClient(dave.socket);
    await d.init(dave.password);
    await openOwnerSession(d, dave.password);
    final sub = Events(a.subscribe());
    addTearDown(sub.close);
    await sub.next<Subscribed>();

    final created = await a.call(InviteRequest(
      trust: 3,
      ttlSecs: 120,
      label: 'dave',
      password: alice.password,
      follow: false,
    ));
    final id = (created as InviteCreatedReply).invite.id;
    final link = created.invite.link;
    final join = Events(d.open(JoinRequest(
        link: link, trust: 3, label: 'alice', connectTimeoutMs: 5000, password: dave.password)));
    InviteInfo? withCode;
    await _until(() async {
      withCode = (await a.pairings(password: alice.password)).where((i) => i.id == id && i.sas != null).firstOrNull;
      return withCode != null;
    });
    // Before the joiner's entry there is nothing to confirm.
    await expectLater(a.pairingConfirm(id, alice.password), throwsA(isA<XControlException>()));
    await join.next<NeedInput>((e) => e.isSasCode);
    join.dialog.input(SasCodeInput(withCode!.sas!));
    // Subscribers learn the offer from the `invite` event (without the link and the code).
    final ev = await sub.next<InviteEvent>((e) => e.invite.id == id && e.invite.needsConfirm);
    expect(ev.invite.confirmWithoutCode, isTrue);
    expect(ev.invite.sas, isNull);
    // The password is still checked: a wrong one confirms nothing.
    await expectLater(a.pairingConfirm(id, 'wrong-password'), throwsA(_code(XErrorCode.wrongPassword)));
    final r = await a.pairingConfirm(id, alice.password);
    expect(r.contact, 'dave');
    final rd = await join.dialog.result as LinkedReply;
    expect(rd.linkId, r.linkId);
    print('PAIRINGS LIST: invite event confirm_without_code → pairing_confirm {id, password} → linked');
  }, skip: antennad == null ? noXdReason : false);
}
