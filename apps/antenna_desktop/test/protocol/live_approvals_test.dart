// SPDX-License-Identifier: AGPL-3.0-only
// Approvals housekeeping (D-84) against a REAL daemon: the window's `deny` without a password is accepted, even from
// a connection without an owner session; approving still needs the password; a request nobody answers closes by
// itself and the window drops it from the list and the conversation. The daemon runs with a short request lifetime
// (`--approval-ttl-ms`, test-only; it can only shorten the 10 minutes).
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test test/protocol/live_approvals_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 15), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';

  test('deny without a password, expiry closes the request in the window', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!, extraArgs: ['--approval-ttl-ms', '3000']);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket);
    try {
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
      final bobLink = (await a.contacts()).single.linkId;
      final agent = await a.agentAdd('jarvis', localLevel: 5, password: alice.password, links: ['bob']);

      // The window: signed in, subscribed, the conversation with bob open.
      await m.connect();
      expect(m.phase, Phase.loginRequired);
      expect(await m.login(alice.password), isNull);
      await until(() => m.subscribed, what: 'subscription');
      await m.select(bobLink);

      Future<String> agentAsks(String text) async {
        final r = await Process.run(xCli!, ['--json', 'send', 'bob', text, '--wait', '0'],
            environment: {'ANTENNA_AGENT_TOKEN': agent.token, 'ANTENNA_SOCKET': alice.socket});
        expect(r.exitCode, 77, reason: '${r.stdout}');
        return RegExp(r'"id":"([a-z0-9]+)"').firstMatch('${r.stdout}')!.group(1)!;
      }

      // 1) Nobody answers: the daemon closes the request, the window drops it.
      final first = await agentAsks('project details');
      await until(() => m.approvals.containsKey(first), what: 'pending in the window');
      expect(m.approvals[first]!.linkId, bobLink);
      expect(m.approvalsFor(bobLink).map((x) => x.id), [first], reason: 'the card in the conversation');
      final sw = Stopwatch()..start();
      await until(() => !m.approvals.containsKey(first), what: 'expired', timeout: const Duration(seconds: 10));
      print('WINDOW: the expired request left the list ${sw.elapsedMilliseconds} ms after it appeared (lifetime 3000 ms)');
      expect(m.approvalsFor(bobLink), isEmpty);

      // 2) Deny from the window: no password.
      final second = await agentAsks('more details');
      await until(() => m.approvals.containsKey(second), what: 'second pending');
      expect(await m.deny(second), isNull);
      expect(m.approvals.containsKey(second), isFalse);

      // 3) Approving still needs the password; denying works even without an owner session (like `lock`).
      final third = await agentAsks('even more');
      final noSession = XControlClient(alice.socket);
      expect((await noSession.hello()).session, 'none');
      await expectLater(noSession.approve(third, 'wrong-password'),
          throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.wrongPassword)));
      final denied = await noSession.deny(third);
      expect(denied.state, 'denied');
      await until(() => !m.approvals.containsKey(third), what: 'third denied in the window');
      print('WINDOW: deny without password and without a session: ${denied.state}');
    } finally {
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 2)));
}
