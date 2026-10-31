// SPDX-License-Identifier: AGPL-3.0-only
// The antenna_proto::control client (x-control/1) against REAL `antennad` daemons: two nodes in temporary directories,
// pairing over the protocol (link → code on B → confirmation on A, the owner password on every trust command),
// messages both ways, history, event subscription, trust level change, PQ facts from the daemon's state.
//
// The tests are one scenario in order (init in the second, the link in the fourth).
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test test/protocol/live_daemon_test.dart
@Tags(['live'])
library;

import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/invite_link.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Matcher _code(String c) => isA<XControlException>().having((e) => e.code, 'code', c);

void main() {
  final antennad = findXd();
  late Directory root;
  late XdNode alice;
  late XdNode bob;
  late XControlClient a;
  late XControlClient b;

  setUpAll(() async {
    if (antennad == null) return;
    root = await tempRoot();
    alice = XdNode('alice', root, antennad);
    bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    a = XControlClient(alice.socket);
    b = XControlClient(bob.socket);
  });

  tearDownAll(() async {
    if (antennad == null) return;
    await Future.wait([alice.stop(), bob.stop()]);
    await root.delete(recursive: true);
  });

  test('unreachable socket is reported as XDaemonUnreachable', () async {
    final c = XControlClient('/tmp/definitely-no-antennad-here.sock');
    await expectLater(c.status(), throwsA(isA<XDaemonUnreachable>()));
  });

  test('hello (role, proto), status, init, lock, wrong password, unlock', () async {
    final h = await a.hello();
    expect(h.state, DaemonState.uninitialized);
    expect(h.daemon, startsWith('antennad '));
    expect(h.role, 'owner', reason: 'the GUI must run with the owner role');
    expect(h.proto, controlProto);
    expect(h.session, 'none');
    final s = await a.status();
    expect(s.state, DaemonState.uninitialized);
    expect(s.relay, 'disabled');
    expect(s.links, isNull);
    print('STATUS: daemon=${s.daemon} protocol=${s.protocol} control=${h.proto} role=${h.role} relay=${s.relay}');

    expect(await a.init(alice.password), DaemonState.unlocked);
    expect(await b.init(bob.password), DaemonState.unlocked);
    await expectLater(a.init(alice.password), throwsA(_code(XErrorCode.alreadyInitialized)));
    // v2: without an owner session, a process of the same uid is not the owner.
    await expectLater(a.contacts(), throwsA(_code(XErrorCode.loginRequired)));
    expect(a.login('not-the-password').result, throwsA(_code(XErrorCode.wrongPassword)));
    await openOwnerSession(a, alice.password);
    await openOwnerSession(b, bob.password);
    expect((await a.hello()).session, 'held');
    expect(await a.contacts(), isEmpty);
    expect(await a.lock(), DaemonState.locked);
    await expectLater(a.contacts(), throwsA(_code(XErrorCode.locked)));
    await expectLater(a.unlock('not-the-password'), throwsA(_code(XErrorCode.wrongPassword)));
    expect(await a.unlock(alice.password), DaemonState.unlocked);
    // lock closed the session: the old token no longer works.
    await expectLater(a.contacts(), throwsA(_code(XErrorCode.loginRequired)));
    await openOwnerSession(a, alice.password);
    expect((await a.status()).links, 0);
    print('SESSION: login_required without a session; held session via login {hold}; lock closes it');
  }, skip: antennad == null ? noXdReason : false);

  test('owner commands need the owner password; wrong code at B burns the invite', () async {
    // Q-12a: no invite without the right password.
    final bad = a.open(const InviteRequest(trust: 3, ttlSecs: 120, label: 'x', password: 'wrong-password'));
    await expectLater(bad.result, throwsA(_code(XErrorCode.wrongPassword)));

    // Levels 1–2 need a relay (relay only, SPEC §4); the test node has the relay off, hence 3.
    final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'mallory', password: alice.password)));
    final created = await inv.next<InviteCreated>();
    // v5 (D-74): people get the web address of the handler site; the app and preview.1 nodes get antenna://.
    expect(created.link, startsWith('https://antenna.contact/#'));
    expect(created.linkApp, startsWith('antenna://pair#'));
    expect(normalizeInviteLink(created.link), isNotNull, reason: 'the join field understands the web link');
    expect(created.id, isNotNull);
    expect(created.netMode, 'direct');
    final join = Events(b.open(JoinRequest(
      link: created.link,
      trust: 3,
      label: 'eve',
      connectTimeoutMs: 5000,
      password: bob.password,
    )));
    final sas = await inv.next<SasEvent>();
    await join.next<NeedInput>((e) => e.isSasCode);
    final wrong = ((int.parse(sas.code) + 1) % 1000000).toString().padLeft(6, '0');
    join.dialog.input(SasCodeInput(wrong));
    Object? errB, errA;
    try {
      await join.dialog.result;
    } catch (e) {
      errB = e;
    }
    try {
      await inv.dialog.result;
    } catch (e) {
      errA = e;
    }
    print('WRONG CODE: B -> $errB; A -> $errA');
    expect(errB, _code(XErrorCode.sasMismatch));
    expect(errA, isA<XControlException>());
    expect(await a.contacts(), isEmpty, reason: 'no link after a wrong code');
    final p = await a.pairings();
    expect(p.where((i) => i.id == created.id).single.phase, 'failed');
  }, skip: antennad == null ? noXdReason : false);

  test('pairing: link, code at B (emoji form of the same code), confirm at A', () async {
    final sw = Stopwatch()..start();
    final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'bob', password: alice.password)));
    final created = await inv.next<InviteCreated>();
    final join = Events(b.open(JoinRequest(
      link: created.link,
      trust: 3,
      label: 'alice',
      connectTimeoutMs: 5000,
      password: bob.password,
    )));
    final sas = await inv.next<SasEvent>();
    expect(sas.code, matches(RegExp(r'^\d{6}$')));
    expect(sas.emoji, isNotNull, reason: 'x-control/1 gives the emoji form (Q-6)');
    expect(sas.emoji!.runes.length, 6);
    print('SAS: 6 digits + emoji form (${sas.emoji!.runes.length} emoji)');
    await join.next<NeedInput>((e) => e.isSasCode);
    join.dialog.input(SasCodeInput(sas.emoji!)); // B types the same code as emoji
    await inv.next<PeerEnteredCode>();
    // D-95: a daemon that offers the confirmation without the code links on a "yes" (or an empty code) without one;
    // that path is in live_pairing_confirm_test.dart. The checks of a missing code below are for older daemons.
    final offered = (await inv.next<NeedInput>((e) => e.isConfirm)).confirmWithoutCode;
    // While the invite is alive, the daemon hands out the link and code only with the password.
    final hidden = (await a.pairings()).singleWhere((i) => i.id == created.id);
    expect(hidden.link, isEmpty);
    expect(hidden.sas, isNull);
    expect(hidden.phase, 'needs_confirm');
    await expectLater(a.pairings(password: 'wrong-password'), throwsA(_code(XErrorCode.wrongPassword)));
    final shown = (await a.pairings(password: alice.password)).singleWhere((i) => i.id == created.id);
    expect(shown.link, created.link);
    expect(shown.sas, sas.code);
    // pairing_confirm: a typed code is checked against this invite's code; before D-95 the code is required.
    if (!offered) {
      await expectLater(a.pairingConfirm(created.id!, alice.password, code: ''), throwsA(_code(XErrorCode.badRequest)));
    }
    final wrong = ((int.parse(sas.code) + 1) % 1000000).toString().padLeft(6, '0');
    await expectLater(
      a.pairingConfirm(created.id!, alice.password, code: wrong),
      throwsA(_code(XErrorCode.sasMismatch)),
    );
    expect((await a.pairings()).singleWhere((i) => i.id == created.id).phase, 'needs_confirm',
        reason: 'a wrong code does not burn the invite');
    // v2: "yes" with a wrong code on the monitoring connection → an input_rejected event; the invite stays alive.
    inv.dialog.input(ConfirmInput(true, code: wrong));
    final rej = await inv.next<InputRejected>();
    expect(rej.what, 'confirm');
    expect(rej.code, XErrorCode.sasMismatch);
    if (!offered) {
      inv.dialog.input(const ConfirmInput(true));
      expect((await inv.next<InputRejected>()).code, XErrorCode.badRequest, reason: '"yes" without a code');
    }
    // Typed by owner A as read out by B: no second password, on the same connection.
    inv.dialog.input(ConfirmInput(true, code: sas.code));
    final ra = await inv.dialog.result as LinkedReply;
    print('INPUT_REJECTED: wrong code → ${rej.code}; ${offered ? 'offered without a code (D-95)' : 'no code → '
        'bad_request'}; typed code → linked');
    final rb = await join.dialog.result as LinkedReply;
    print('PAIRING: ${sw.elapsedMilliseconds} ms wall, pairing_ms A=${ra.pairingMs} B=${rb.pairingMs}');
    expect(ra.linkId, rb.linkId);
    expect(ra.kxGroup, 'X25519MLKEM768');
    expect(rb.kxGroup, 'X25519MLKEM768');
    expect(ra.contact, 'bob');
    expect(rb.contact, 'alice');
  }, skip: antennad == null ? noXdReason : false);

  test('subscribe + send both ways + history + PQ facts', () async {
    final ca = (await a.contacts()).single;
    final cb = (await b.contacts()).single;
    expect(ca.label, 'bob');
    expect(cb.label, 'alice');
    expect(ca.linkId, cb.linkId);
    expect(ca.role, 'inviter');
    expect(cb.role, 'joiner');
    expect(ca.trust, 3);
    expect(ca.netMode, 'direct');
    expect(ca.localEndpoint, cb.peerEndpoint, reason: 'pairwise endpoints');
    expect(ca.transport.pairingKxGroup, 'X25519MLKEM768');
    expect(ca.peerKind, 'unknown', reason: 'agent sub-identities are v0.2');

    final subA = Events(a.subscribe());
    final subB = Events(b.subscribe());
    expect((await subA.next<Subscribed>()).role, 'owner');
    await subB.next<Subscribed>();

    final sw = Stopwatch()..start();
    final s1 = await a.send('bob', 'hello Bob, ça va?');
    expect(s1.status, 'delivered');
    final inB = await subB.next<MessageEvent>((e) => !e.message.outgoing);
    print('SUBSCRIBE: A send → B message event in ${sw.elapsedMilliseconds} ms');
    expect(inB.message.text, 'hello Bob, ça va?');
    expect(inB.message.id, s1.id);
    expect(inB.message.status, 'received');
    expect(inB.linkId, ca.linkId);
    final outA = await subA.next<MessageEvent>((e) => e.message.outgoing);
    expect(outA.message.id, s1.id);
    final st = await subA.next<MessageStatusEvent>((e) => e.id == s1.id);
    expect(st.status, 'delivered');

    final s2 = await b.send('alice', 'hi Alice');
    expect(s2.parents, [s1.id], reason: 'DAG: reply references the head');
    final inA = await subA.next<MessageEvent>((e) => !e.message.outgoing);
    expect(inA.message.text, 'hi Alice');
    await a.send('bob', '3');
    await b.send('alice', '4');
    await subA.next<MessageEvent>((e) => e.message.text == '4');

    // History: both sides, statuses, pages.
    final h = await a.history('bob');
    expect(h.linkId, ca.linkId);
    expect([for (final m in h.messages) m.text], ['hello Bob, ça va?', 'hi Alice', '3', '4']);
    expect([for (final m in h.messages) m.direction], ['out', 'in', 'out', 'in']);
    expect(h.messages.where((m) => m.outgoing).every((m) => m.status == 'delivered'), isTrue);
    expect(h.nextBefore, isNull, reason: 'whole history fits one page');
    final p1 = await a.history('bob', limit: 2);
    expect([for (final m in p1.messages) m.text], ['3', '4']);
    expect(p1.nextBefore, isNotNull);
    final p2 = await a.history('bob', limit: 2, before: p1.nextBefore);
    expect([for (final m in p2.messages) m.text], ['hello Bob, ça va?', 'hi Alice']);
    print('HISTORY: 4 messages, pages of 2: next_before=${p1.nextBefore} → ${p2.nextBefore}');

    // History does not touch the inbox: unread messages stay for the CLI and agents.
    expect((await a.inbox()).length, 2);

    final fa = (await a.contacts()).single;
    final fb = (await b.contacts()).single;
    for (final c in [fa, fb]) {
      expect(c.transport.lastKxGroup, 'X25519MLKEM768');
      expect(c.e2e.sessionVersion, 4);
      expect(c.e2e.pqRatchet, 'NegotiationComplete(V1)');
      expect(c.e2e.lastRxVersion, 4);
      expect(c.e2e.lastRxPqLen, greaterThan(0));
      expect(c.lamport, 4);
      expect(c.outbox, 0);
      expect(c.failed, 0);
      expect(c.presence, 'online');
    }
    expect(fa.heads, fb.heads, reason: 'both sides agree on the head');
    print('FACTS: tls=${fa.transport.lastKxGroup} session_version=${fa.e2e.sessionVersion} '
        'spqr=${fa.e2e.pqRatchet} last_rx_pq_len=${fa.e2e.lastRxPqLen} presence=${fa.presence} '
        'paths=${fa.transport.lastPaths}');
    await subA.close();
    await subB.close();
  }, skip: antennad == null ? noXdReason : false);

  test('trust needs the password, emits a contact event; approvals and audit log', () async {
    final sub = Events(a.subscribe());
    await sub.next<Subscribed>();
    await expectLater(a.trust('bob', 4, 'wrong-password'), throwsA(_code(XErrorCode.wrongPassword)));
    final c = await a.trust('bob', 4, alice.password);
    expect(c.trust, 4);
    expect(c.netMode, 'direct');
    final ev = await sub.next<ContactEvent>((e) => e.contact.trust == 4);
    expect(ev.contact.contact, 'bob');
    print('TRUST: bob 3 → 4, contact event presence=${ev.contact.presence}');
    final ap = await a.approvals(all: true);
    expect(ap.approvals, isEmpty);
    final log = await a.log('bob');
    print('LOG: ${log.length} receipts for bob');
    await sub.close();
  }, skip: antennad == null ? noXdReason : false);

  test('offline contact: queued, then message_status delivered after it returns', () async {
    final sub = Events(a.subscribe());
    await sub.next<Subscribed>();
    await bob.stop();
    final s = await a.send('bob', 'while you were away', wait: const Duration(milliseconds: 300));
    expect(s.status, 'queued');
    expect((await a.contacts()).single.outbox, 1);
    final queued = await sub.next<MessageEvent>((e) => e.message.id == s.id);
    expect(queued.message.status, 'queued');
    await bob.start();
    expect(await b.unlock(bob.password), DaemonState.unlocked);
    await openOwnerSession(b, bob.password);
    final sw = Stopwatch()..start();
    final st = await sub.next<MessageStatusEvent>((e) => e.id == s.id);
    expect(st.status, 'delivered');
    print('QUEUE: delivered ${sw.elapsedMilliseconds} ms after bob unlocked');
    final hb = await b.history('alice');
    expect(hb.messages.last.text, 'while you were away');
    await sub.close();
  }, skip: antennad == null ? noXdReason : false);

  test('lock ends the subscription with err locked', () async {
    final sub = Events(a.subscribe());
    await sub.next<Subscribed>();
    await a.lock();
    await expectLater(sub.dialog.result, throwsA(_code(XErrorCode.locked)));
    await sub.close();
    expect(await a.unlock(alice.password), DaemonState.unlocked);
    await openOwnerSession(a, alice.password);
  }, skip: antennad == null ? noXdReason : false);
}
