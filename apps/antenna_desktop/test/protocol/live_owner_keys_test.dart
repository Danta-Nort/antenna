// SPDX-License-Identifier: AGPL-3.0-only
// Owner keys and proofs (x-control/7, CONTROL §22, D-102) against a REAL daemon, with the published test key signing
// in software in place of the Secure Enclave (CONTROL §22.5: only a debug build started with ANTENNA_OWNER_TEST_KEY=1
// accepts it). The signature is made by `openssl` over the message of §22.2, built here byte by byte, and converted from
// DER to the 64-byte r ‖ s; nothing in the window computes it.
//
// 1. The window's flows (AppModel with a software Touch ID host): enroll with the password and a proof by the new key,
//    approve one request and a batch with one proof each, lock → unlock with the slot key → sign in under the same
//    touch, sign in alone, turn Touch ID off.
// 2. Enrolling when the password is due: the enroll challenge is issued anyway, and owner_key_add carries the password.
//    A challenge serves its purpose only: a sign-in proved over an enroll challenge is `challenge_invalid`, and
//    `password_required` while the password is due.
// 3. What the daemon refuses at the protocol level: a tampered fingerprint (`approval_mismatch`), a proof over another
//    text (`proof_invalid`), a used challenge and a challenge of the other kind both ways (`challenge_invalid`), a key
//    that is not enrolled (`owner_key_unknown`),
//    a password next to a proof, an enrollment proved by another key, a wrong slot key (`slot_invalid`).
// Run: ANTENNAD_BIN=<path to a debug antennad> nice -n 10 flutter test --tags live test/protocol/live_owner_keys_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/soft_owner_key.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 15), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Matcher _code(String code) => isA<XControlException>().having((e) => e.code, 'code', code);

/// Alice (owner keys allowed for the test key) and Bob, linked at level 3; Alice's agent `jarvis` (data label 5) must
/// ask before it sends to Bob.
Future<(XdNode, XdNode, XControlClient, String)> _nodes(Directory root, String antennad) async {
  final alice = XdNode('alice', root, antennad, env: const {'ANTENNA_OWNER_TEST_KEY': '1'});
  final bob = XdNode('bob', root, antennad);
  await Future.wait([alice.start(), bob.start()]);
  final a = XControlClient(alice.socket);
  final b = XControlClient(bob.socket);
  await a.init(alice.password);
  await b.init(bob.password);
  await openOwnerSession(a, alice.password);
  await openOwnerSession(b, bob.password);
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
  await join.next<NeedInput>((e) => e.isSasCode);
  join.dialog.input(SasCodeInput(sas.code));
  await inv.next<NeedInput>((e) => e.isConfirm);
  inv.dialog.input(ConfirmInput(true, code: sas.code));
  await join.dialog.result;
  final agent = await a.agentAdd('jarvis', localLevel: 5, password: alice.password, links: ['bob']);
  return (alice, bob, a, agent.token);
}

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final haveOpenssl = hasOpenssl();
  final skip = antennad == null ? noXdReason : (!haveOpenssl ? 'openssl not found: it signs with the test key' : false);

  Future<String> agentAsks(String socket, String token, String text) async {
    final r = await Process.run(xCli!, ['--json', 'send', 'bob', text, '--wait', '0'],
        environment: {'ANTENNA_AGENT_TOKEN': token, 'ANTENNA_SOCKET': socket});
    expect(r.exitCode, 77, reason: '${r.stdout}${r.stderr}');
    return RegExp(r'"id":"([a-z0-9]+)"').firstMatch('${r.stdout}')!.group(1)!;
  }

  test('the test key: its point and key ID as CONTROL §22.5 publishes them', () async {
    final (point, id) = await publicOf(testKeyPem);
    expect((point, id), (testPublicKey, testKeyId));
  }, skip: haveOpenssl ? false : 'openssl not found');

  test('the window: enroll, approve one and a batch, unlock and sign in with one touch, turn off', () async {
    final root = await tempRoot();
    final (alice, bob, a, token) = await _nodes(root, antennad!);
    final soft = SoftwareTouchId();
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket, touchId: soft);
    try {
      await m.connect();
      expect(m.hello?.proto, 'x-control/7', reason: 'the daemon under test speaks x-control/7');
      expect(await m.login(alice.password), isNull);
      await until(() => m.subscribed, what: 'subscription');
      expect(m.touchIdOffered, isTrue);

      // Enroll: the password and a proof by the new key, one touch; the slot key sealed (here: kept in memory).
      expect(await m.enrollTouchId(alice.password, reason: 'turn on Touch ID for Antenna'), isNull);
      expect((m.ownerKeyRecord?.keyId, m.ownerKeyRecord?.unlock), (testKeyId, true));
      final listed = await a.ownerKeyList();
      expect(listed.testKey, isTrue, reason: 'a debug build started with ANTENNA_OWNER_TEST_KEY=1');
      expect([for (final k in listed.keys) (k.keyId, k.unlock)], [(testKeyId, true)]);
      expect(soft.prompts, [('sign', 'turn on Touch ID for Antenna', false)]);
      print('ENROLL: key $testKeyId enrolled with an unlock slot; password due ${listed.passwordDueMs}');

      // One request, one touch: the signed text names its ID and fingerprint.
      final one = await agentAsks(alice.socket, token, 'the release notes');
      await until(() => m.approvals.containsKey(one), what: 'pending in the window');
      final shown = m.approvals[one]!;
      expect(await m.approveWithTouchId(shown, reason: 'approve sending a message to bob'), isNull);
      expect(m.approvals.containsKey(one), isFalse);
      expect(jsonDecode(soft.signed.last), {'cmd': 'approve', 'id': one, 'password': '', 'fingerprint': shown.fingerprint});
      final decided = (await a.approvals(all: true)).approvals.firstWhere((x) => x.id == one);
      expect(decided.state, isNot('pending'));
      print('APPROVE: ${decided.state} with one proof');

      // A batch, one touch: one approve_many naming both.
      final two = await agentAsks(alice.socket, token, 'second');
      final three = await agentAsks(alice.socket, token, 'third');
      await until(() => m.approvals.containsKey(two) && m.approvals.containsKey(three), what: 'two pending');
      final before = soft.prompts.length;
      final (results, err) = await m.approveManyWithTouchId([m.approvals[two]!, m.approvals[three]!],
          reason: 'approve 2 requests from jarvis');
      expect(err, isNull);
      expect([for (final r in results) (r.id, r.approval?.state)], [(two, 'approved'), (three, 'approved')]);
      expect(soft.prompts.length - before, 1, reason: 'one touch for the batch');
      print('APPROVE_MANY: ${results.length} approved with one proof');

      // D-131: the other owner commands with one touch each, through the real client: the proving view signs the one
      // typed request it sends, and the daemon checks it.
      final p1 = soft.prompts.length;
      final bobLink = m.contacts.firstWhere((c) => c.label == 'bob').linkId;
      expect(await m.setTrust(bobLink, 4, const TouchAuth('confirm “change bob to 4”')), isNull);
      expect((await a.contacts()).firstWhere((c) => c.label == 'bob').trust, 4);
      final (added, addErr) =
          await m.addAgent(name: 'helper', localLevel: 3, auth: const TouchAuth('issue a token for the agent helper'));
      expect(addErr, isNull);
      expect(added?.name, 'helper');
      expect(await m.removeAgent('helper', const TouchAuth('confirm “revoke helper”')), isNull);
      expect(soft.prompts.length - p1, 3, reason: 'one touch each');
      final signed = [for (final t in soft.signed.sublist(soft.signed.length - 3)) jsonDecode(t) as Map<String, Object?>];
      expect([for (final j in signed) (j['cmd'], j['password'])],
          [('trust', ''), ('agent_add', ''), ('agent_remove', '')]);
      expect((await a.agents()).any((x) => x.name == 'helper'), isFalse);
      print('OWNER_COMMANDS: trust, agent_add, agent_remove with one proof each');

      // Lock, then one touch: the slot key unlocks, the same touch signs the sign-in.
      await m.lock();
      expect(m.phase, Phase.locked);
      final p0 = soft.prompts.length;
      expect(await m.unlockWithTouchId(reason: 'unlock Antenna and sign in'), isNull);
      expect(m.phase, Phase.unlocked);
      expect(soft.prompts.sublist(p0), [
        ('openSlot', 'unlock Antenna and sign in', false),
        ('sign', 'unlock Antenna and sign in', true),
      ]);
      expect(jsonDecode(soft.signed.last), {'cmd': 'login', 'password': '', 'hold': true});
      final other = XControlClient(alice.socket)..sessionToken = m.daemon.sessionToken;
      expect((await other.hello()).session, 'held', reason: 'the session the proof opened');
      print('UNLOCK: by the slot and signed in with one touch');

      // Sign in alone (keys unlocked, no session).
      await m.logout();
      expect(m.phase, Phase.loginRequired);
      expect(await m.signInWithTouchId(reason: 'sign in to Antenna'), isNull);
      expect(m.phase, Phase.unlocked);
      await until(() => m.subscribed, what: 'subscription after the sign-in');

      // Off: the daemon forgets the key and its slot; no password.
      expect(await m.disableTouchId(), isNull);
      // The lock above closed every session, the test's own client's too: ask with the window's.
      expect((await m.daemon.ownerKeyList()).keys, isEmpty);
      expect(m.ownerKeyRecord, isNull);
    } finally {
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  /// Negative control (seen failing): the window enrolled with a plain challenge; the daemon answered
  /// `password_required`.
  test('enrolling when the password is due: the enroll challenge, and nothing else spends the password', () async {
    final root = await tempRoot();
    // The test-only flag can only shorten the 14 days.
    final alice = XdNode('alice', root, antennad!,
        extraArgs: const ['--owner-password-every-ms', '1500'], env: const {'ANTENNA_OWNER_TEST_KEY': '1'});
    await alice.start();
    final soft = SoftwareTouchId();
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket, touchId: soft, live: false);
    try {
      expect(await XControlClient(alice.socket).init(alice.password), DaemonState.unlocked);
      await m.connect();
      expect(await m.login(alice.password), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      await expectLater(m.daemon.ownerChallenge(), throwsA(_code(XErrorCode.passwordRequired)),
          reason: 'proofs are refused until the password is used: asked before any Touch ID prompt');
      expect(await m.enrollTouchId(alice.password, reason: 'turn on Touch ID for Antenna'), isNull);
      expect(m.ownerKeyRecord?.keyId, testKeyId);
      expect(soft.prompts, hasLength(1), reason: 'one touch, after the password');
      expect(jsonDecode(soft.signed.single)['cmd'], 'owner_key_add');

      // An enroll challenge proves nothing but an enrollment: a sign-in signed over it is refused, as a challenge of
      // the wrong kind while the password is fresh, and first of all for the password once it is due again.
      Future<Reply> signInOverEnroll() async {
        final ch = await m.daemon.ownerChallenge(enroll: true);
        return m.daemon.callWithProof(const LoginRequest('', hold: false),
            (req) async => OwnerProof(keyId: testKeyId, nonce: ch.nonce, sig: await softSign(testKeyPem, ch.nonce, req)));
      }

      await expectLater(signInOverEnroll(), throwsA(_code(XErrorCode.challengeInvalid)));
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      await expectLater(signInOverEnroll(), throwsA(_code(XErrorCode.passwordRequired)));
    } finally {
      m.dispose();
      await alice.stop();
      await root.delete(recursive: true);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('what the daemon refuses: tampered fingerprint, another text, a used challenge, unknown and foreign keys, '
      'a password next to a proof, a wrong slot key', () async {
    final root = await tempRoot();
    final (alice, bob, a, token) = await _nodes(root, antennad!);
    final other = '${root.path}/other.pem';
    await openssl(['genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', other], const []);
    final (otherPoint, otherId) = await publicOf(other);
    // A correct password resets the proof counter and the D-37 pause (CONTROL §22.2): used between failures.
    Future<void> reset() => a.pairings(password: alice.password);
    ProofSource by(String pem, String keyId, String nonce, {String? signText}) =>
        (req) async => OwnerProof(keyId: keyId, nonce: nonce, sig: await softSign(pem, nonce, signText ?? req));
    try {
      expect((await a.hello()).proto, 'x-control/7', reason: 'the daemon under test speaks x-control/7');

      final enroll =
          OwnerKeyAddRequest(publicKey: testPublicKey, label: 'touchid@test', password: alice.password, unlock: true);

      // Enrolling takes a proof by the key it enrolls: one by another key is refused, nothing is enrolled.
      var ch = await a.ownerChallenge(enroll: true);
      await expectLater(a.callWithProof(enroll, by(other, otherId, ch.nonce)), throwsA(isA<XControlException>()));
      expect((await a.ownerKeyList()).keys, isEmpty);
      await reset();

      // Enrolling takes only an enroll challenge: a plain one is a challenge of the wrong kind.
      ch = await a.ownerChallenge();
      await expectLater(
          a.callWithProof(enroll, by(testKeyPem, testKeyId, ch.nonce)), throwsA(_code(XErrorCode.challengeInvalid)));
      expect((await a.ownerKeyList()).keys, isEmpty);
      await reset();

      ch = await a.ownerChallenge(enroll: true);
      final added = expectReply<OwnerKeyAddedReply>(await a.callWithProof(enroll, by(testKeyPem, testKeyId, ch.nonce)));
      expect(added.key.keyId, testKeyId);
      final slotKey = added.slotKey!;
      expect(base64.decode(slotKey), hasLength(32));

      final id = await agentAsks(alice.socket, token, 'the budget');
      final fp = (await a.approvals()).approvals.firstWhere((x) => x.id == id).fingerprint;

      // A tampered fingerprint, signed: the proof holds, the request does not match what was asked.
      ch = await a.ownerChallenge();
      await expectLater(
        a.callWithProof(ApproveRequest(id: id, password: '', fingerprint: '0000000000000000'),
            by(testKeyPem, testKeyId, ch.nonce)),
        throwsA(_code(XErrorCode.approvalMismatch)),
      );

      // A proof over another text than the line carries.
      ch = await a.ownerChallenge();
      final wrong = '{"cmd":"approve","id":"$id","password":"","fingerprint":"0000000000000000"}';
      await expectLater(
        a.callWithProof(ApproveRequest(id: id, password: '', fingerprint: fp), by(testKeyPem, testKeyId, ch.nonce, signText: wrong)),
        throwsA(_code(XErrorCode.proofInvalid)),
      );
      // A password next to a proof.
      final ch2 = await a.ownerChallenge();
      await expectLater(
        a.callWithProof(ApproveRequest(id: id, password: alice.password, fingerprint: fp), by(testKeyPem, testKeyId, ch2.nonce)),
        throwsA(_code(XErrorCode.badRequest)),
      );
      await reset();

      // The right one; then the same challenge again.
      ch = await a.ownerChallenge();
      final ok = expectReply<ApprovalReply>(await a.callWithProof(
          ApproveRequest(id: id, password: '', fingerprint: fp), by(testKeyPem, testKeyId, ch.nonce)));
      expect(ok.approval.state, isNot('pending'));
      final id2 = await agentAsks(alice.socket, token, 'again');
      final fp2 = (await a.approvals()).approvals.firstWhere((x) => x.id == id2).fingerprint;
      await expectLater(
        a.callWithProof(ApproveRequest(id: id2, password: '', fingerprint: fp2), by(testKeyPem, testKeyId, ch.nonce)),
        throwsA(_code(XErrorCode.challengeInvalid)),
      );
      // An enroll challenge serves only an enrollment: an approval signed over it is a challenge of the wrong kind.
      ch = await a.ownerChallenge(enroll: true);
      await expectLater(
        a.callWithProof(ApproveRequest(id: id2, password: '', fingerprint: fp2), by(testKeyPem, testKeyId, ch.nonce)),
        throwsA(_code(XErrorCode.challengeInvalid)),
      );
      await reset();
      // A key that is not enrolled.
      ch = await a.ownerChallenge();
      await expectLater(
        a.callWithProof(ApproveRequest(id: id2, password: '', fingerprint: fp2), by(other, otherId, ch.nonce)),
        throwsA(_code(XErrorCode.ownerKeyUnknown)),
      );
      expect(otherPoint, isNot(testPublicKey));
      await reset();

      // A batch with one proof: every item and its fingerprint in the signed text.
      final id3 = await agentAsks(alice.socket, token, 'third');
      final pending = (await a.approvals()).approvals.where((x) => x.id == id2 || x.id == id3).toList();
      ch = await a.ownerChallenge();
      final batch = expectReply<ApprovalsDecidedReply>(await a.callWithProof(
        ApproveManyRequest(items: [for (final x in pending) ApproveItem(x.id, fingerprint: x.fingerprint)], password: ''),
        by(testKeyPem, testKeyId, ch.nonce),
      ));
      expect(batch.results.every((r) => r.ok), isTrue, reason: '${[for (final r in batch.results) r.error]}');

      // Sign in with a proof from a connection without a session.
      final fresh = XControlClient(alice.socket);
      final fch = await fresh.ownerChallenge();
      final session = Events(fresh.openWithProof(const LoginRequest(''), by(testKeyPem, testKeyId, fch.nonce)));
      final ev = await session.next<SessionEvent>();
      expect(ev.mode, 'held');

      // Lock; a wrong slot key does not open; the right one does.
      await a.lock();
      final c = XControlClient(alice.socket);
      await expectLater(c.unlockWithSlot(testKeyId, base64.encode(List.filled(32, 7))), throwsA(_code(XErrorCode.slotInvalid)));
      expect(await c.unlockWithSlot(testKeyId, slotKey), DaemonState.unlocked);
      print('REFUSED: approval_mismatch, proof_invalid, bad_request, challenge_invalid (used; the wrong kind both ways), '
          'owner_key_unknown, slot_invalid');
      await session.close();
    } finally {
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
