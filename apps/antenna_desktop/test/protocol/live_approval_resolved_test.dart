// SPDX-License-Identifier: AGPL-3.0-only
// After the owner approves, the daemon finishes the agent's action itself (x-control/6) — against a REAL daemon. An
// agent sends a message with a secret to a level-4 contact and gets `approval_required`; the owner approves in the
// window; the owner's subscription gets `approval_resolved{completed}`, the message is in the history on both sides,
// and the agent never repeats its call. The window's card goes from "finishing" to gone.
// A daemon that does not finish approved actions yet (no `completes` on the request) skips the test with a reason.
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_approval_resolved_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
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

const secretText = 'password: hunter2hunter2';

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';

  test('approve once: the daemon sends the agent\'s message itself and reports approval_resolved', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final m = AppModel(connector: XControlClient.new, socketPath: alice.socket);
    Events? sub;
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(a, alice.password);
      await openOwnerSession(b, bob.password);
      // Alice trusts Bob at level 4: a secret to him needs her approval (level 5 would not).
      final inv = Events(a.open(InviteRequest(trust: 4, ttlSecs: 120, label: 'bob', password: alice.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
        link: created.link,
        trust: 4,
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
      final aliceLink = (await b.contacts()).single.linkId;
      // Data label 0: only the secret holds the message, not the agent's label.
      final agent = await a.agentAdd('jarvis', localLevel: 0, password: alice.password, links: ['bob']);

      // The owner's own subscription, next to the window's.
      sub = Events(a.subscribe());
      await sub.next<Subscribed>();
      await m.connect();
      expect(await m.login(alice.password), isNull);
      await until(() => m.subscribed, what: 'window subscription');
      await m.select(bobLink);

      // The agent sends once and is held for the secret.
      var agentCalls = 0;
      final r = await Process.run(xCli!, ['--json', 'send', 'bob', secretText, '--wait', '0'],
          environment: {'ANTENNA_AGENT_TOKEN': agent.token, 'ANTENNA_SOCKET': alice.socket});
      agentCalls++;
      expect(r.exitCode, 77, reason: '${r.stdout} ${r.stderr}');
      final id = RegExp(r'"id":"([a-z0-9]+)"').firstMatch('${r.stdout}')!.group(1)!;
      await until(() => m.approvals.containsKey(id), what: 'the request in the window');
      final pending = m.approvals[id]!;
      expect(pending.action, 'send_message');
      if (!pending.completes) {
        markTestSkipped('this antennad does not finish approved actions yet (no `completes` on the request, no '
            '`approval_resolved`): build the daemon with x-control/6 approval completion and run again');
        return;
      }
      expect(m.approvalsFor(bobLink).map((x) => x.id), [id], reason: 'the card in the conversation');

      // The owner approves in the window; nobody tells the agent anything.
      final sw = Stopwatch()..start();
      expect(await m.approve(id, alice.password), isNull);
      expect(m.approvals.containsKey(id), isFalse);
      final resolved = await sub.next<ApprovalResolvedEvent>((e) => e.id == id);
      print('DAEMON: approval_resolved{${resolved.state}} ${sw.elapsedMilliseconds} ms after approve: '
          '${resolved.message}');
      expect(resolved.state, 'completed');
      expect(resolved.action, 'send_message');
      expect(resolved.requester, 'jarvis');
      expect(resolved.error, isNull);
      expect(resolved.resultType, 'sent');
      await until(() => !m.finishing.containsKey(id), what: 'the finishing card leaves');
      expect(m.finishingFor(bobLink), isEmpty);

      // The message is in the history, on both sides, once; the agent did not repeat its call.
      await until(() => m.chatOf(bobLink).any((e) => e.text == secretText), what: 'the message in the window');
      final mine = (await a.history(bobLink)).messages.where((x) => x.text == secretText).toList();
      expect(mine, hasLength(1));
      expect(mine.single.outgoing, isTrue);
      expect(mine.single.viaAgent, 'jarvis');
      final sw2 = Stopwatch()..start();
      List<HistoryItem> theirs = const [];
      while (sw2.elapsed < const Duration(seconds: 15)) {
        theirs = (await b.history(aliceLink)).messages.where((x) => x.text == secretText).toList();
        if (theirs.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(theirs, hasLength(1), reason: 'Bob got it once');
      expect(agentCalls, 1);
      print('WINDOW: ${jsonEncode({'approved': id, 'state': resolved.state, 'agent_calls': agentCalls})}');
    } finally {
      await sub?.close();
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 2)));
}
