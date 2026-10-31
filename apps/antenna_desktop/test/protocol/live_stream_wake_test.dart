// SPDX-License-Identifier: AGPL-3.0-only
// Streaming replies and wake in the window against real antennad (x-control/4, CONTROL §15–§16). Two nodes, each with
// its own window (AppModel): bob turns on "an agent that replies on its own" from the window (a fake agent script
// prints `claude -p --output-format stream-json` events, as in crates/antenna-cli/tests/wake.rs; the real claude is
// never called), and alice writes from her window. Checked: alice's bubble grows chunk by chunk (and bob sees his own
// outgoing one), "what it is doing" at level 4, the final message replaces the bubble; an agent crash → an
// "interrupted" final; a secret in the middle of a reply → "waiting for your approval" on bob's side, and after approval
// the final goes out by itself; the run log and turning it off.
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_stream_wake_test.dart
// (`antenna` next to antennad; needs a Linux sandbox: bwrap or Landlock).
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/state/streams.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 60), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Fake agent (like FAKE_AGENT in crates/antenna-cli/tests/wake.rs): the first argument is the scenario.
const _fakeAgent = r'''#!/bin/bash
mode="$1"
emit() { printf '%s\n' "$1"; }
delta() {
  local t="${1//\\/\\\\}"; t="${t//\"/\\\"}"
  emit "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$t\"}},\"parent_tool_use_id\":null}"
}
inbox=$(antenna --json inbox 2>&1)
text=$(printf '%s' "$inbox" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' | head -n1)
emit '{"type":"system","subtype":"init","session_id":"fake"}'
emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}},"parent_tool_use_id":null}'
emit '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","name":"Read"}},"parent_tool_use_id":null}'
sleep 0.3
delta "You wrote: $text. "
for w in This answer is written word by word so that the window sees it grow; do
  delta "$w "
  sleep 0.12
done
if [ "$mode" = secret ]; then
  delta "my key is -----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW -----END OPENSSH PRIVATE KEY----- "
  delta "and more text after the key. "
fi
if [ "$mode" = crash ]; then exit 3; fi
delta "Done."
emit '{"type":"result","subtype":"success","is_error":false,"result":"ignored"}'
''';

void main() {
  final antennad = findXd();
  final cli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final hasWake = cli != null &&
      File(cli).existsSync() &&
      '${Process.runSync(cli, ['wake', '--help'], environment: ownerCliEnv(), includeParentEnvironment: false).stdout}'
          .contains('set');

  test('live bubble grows, final replaces it; crash → interrupted; secret → waits for approval; log; off', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final script = File('${root.path}/agent-bin/fake-agent')
      ..createSync(recursive: true)
      ..writeAsStringSync(_fakeAgent);
    await Process.run('chmod', ['755', script.path]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final ma = AppModel(connector: XControlClient.new, socketPath: alice.socket, factsEvery: const Duration(seconds: 1));
    final mb = AppModel(connector: XControlClient.new, socketPath: bob.socket, factsEvery: const Duration(seconds: 1));
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await ma.connect();
      await mb.connect();
      expect(await ma.login(alice.password), isNull);
      expect(await mb.login(bob.password), isNull);
      expect(ma.hello?.proto, controlProto);
      a.sessionToken = ma.daemon.sessionToken;
      b.sessionToken = mb.daemon.sessionToken;
      // A level 4 link on both sides: the stream is live and "what it is doing" is visible.
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
      await until(() => ma.contacts.isNotEmpty && ma.subscribed && mb.contacts.isNotEmpty && mb.subscribed,
          what: 'both windows see the link');
      final linkA = ma.contacts.single.linkId; // alice's link to bob
      final linkB = mb.contacts.single.linkId; // bob's link to alice
      await ma.select(linkA);
      await mb.select(linkB);

      Future<void> wake(String mode) async {
        final err = await mb.setWake(
            PasswordAuth(bob.password),
            (pw) => WakeSetRequest(
                  contact: linkB,
                  argv: [script.path, mode, '--output-format', 'stream-json'],
                  password: pw,
                  timeoutSecs: 120,
                ));
        expect(err, isNull, reason: '$err');
      }

      // 1. A streamed reply: alice's bubble grows, and the final message replaces it.
      await wake('reply');
      final rule = mb.wakeRuleOf(linkB)!;
      print('WAKE: agent ${rule.agent}, mode ${rule.mode}, sandbox ${mb.wakeSandbox}');
      expect(rule.mode, 'claude_stream');
      // The wake sandbox is the OS's own: bubblewrap or Landlock on Linux, Seatbelt (sandbox-exec) on macOS.
      expect(mb.wakeSandbox, Platform.isMacOS ? 'seatbelt' : anyOf('bwrap', 'landlock'));
      final grownA = <int>{};
      final grownB = <int>{};
      String? activity;
      void watch() {
        for (final s in ma.streamsOf(linkA)) {
          grownA.add(s.text.length);
          activity ??= s.activity;
        }
        for (final s in mb.streamsOf(linkB)) {
          grownB.add(s.text.length);
        }
      }

      ma.addListener(watch);
      mb.addListener(watch);
      await ma.send('hello from the window');
      await until(() => ma.chatOf(linkA).any((e) => !e.outgoing && e.text.contains('Done.')), what: 'final at alice');
      await until(() => ma.streamsOf(linkA).isEmpty, what: 'alice bubble replaced');
      final reply = ma.chatOf(linkA).lastWhere((e) => !e.outgoing && e.text.contains('Done.'));
      print('STREAM: alice saw ${grownA.length} sizes, bob ${grownB.length}; activity $activity; final "${reply.text}"');
      expect(grownA.length, greaterThan(5), reason: 'the bubble grew in pieces');
      expect(grownB.length, greaterThan(1), reason: "bob's window shows its own agent writing");
      expect(activity, isNotNull, reason: 'level 4 sees what the agent is doing');
      expect(reply.text, contains('You wrote: hello from the window.'));
      // v5 (CONTROL §17): for alice the reply is signed by bob's agent, for bob it is "your agent"; the contact's kind
      // changes on alice's side.
      final mine = mb.chatOf(linkB).lastWhere((e) => e.outgoing && e.text.contains('Done.'));
      await ma.refreshContacts();
      print('V5: alice sees via_agent ${reply.viaAgent}, bob sees via_agent ${mine.viaAgent}, '
          'alice peer_kind ${ma.contacts.single.peerKind}, agents ${ma.contacts.single.agents.map((a) => a.name).toList()}');
      // The announced name is not the local "wake-<label>" (the contact label is bob's data and is not sent to the contact).
      expect(reply.viaAgent, isNotNull);
      expect(mine.viaAgent, reply.viaAgent);
      expect(ma.contacts.single.peerKind, anyOf('agent', 'mixed'));
      expect(ma.contacts.single.agents.map((a) => a.name), contains(reply.viaAgent));
      expect(ma.interruptedFinals.contains(reply.id), isFalse);
      await until(() => mb.wakeRuleOf(linkB)?.last?.outcome == 'ok', what: 'bob: run logged ok');

      // 2. The agent crashed mid-reply: an "interrupted" final.
      await wake('crash');
      await ma.send('second question');
      await until(() => ma.interruptedFinals.isNotEmpty, what: 'interrupted final at alice');
      await until(() => ma.streamsOf(linkA).isEmpty, what: 'bubble replaced by the interrupted final');
      final cut = ma.chatOf(linkA).lastWhere((e) => ma.interruptedFinals.contains(e.id));
      print('CRASH: final "${cut.text}"');
      expect(cut.text, contains('word by word'));
      await until(() => mb.wakeRuleOf(linkB)?.last?.outcome == 'failed', what: 'bob: run logged failed');

      // 3. A secret mid-reply: the stream breaks, bob sees "waiting for your approval", and after approval the final goes
      // out by itself.
      await wake('secret');
      await ma.send('third question');
      await until(() => mb.streamsOf(linkB).any((s) => s.awaitingApproval), what: 'bob: waiting for approval');
      final held = mb.streamsOf(linkB).firstWhere((s) => s.awaitingApproval);
      await until(() => mb.approvals.isNotEmpty, what: 'bob: approval request');
      final ap = mb.approvals.values.first;
      print('SECRET: bob bubble ${held.state.name}/${held.reason}, approval ${ap.id} (${ap.reasons.join(',')})');
      // The daemon shows its own owner what it holds; the contact never saw the secret, neither in the bubble nor in history.
      expect(held.text, contains('PRIVATE KEY'));
      expect(ma.streamsOf(linkA).every((s) => !s.text.contains('PRIVATE KEY') && s.state != LiveStreamState.streaming),
          isTrue);
      expect(ma.chatOf(linkA).any((e) => e.text.contains('PRIVATE KEY')), isFalse);
      expect(await mb.approve(ap.id, bob.password), isNull);
      await until(() => ma.chatOf(linkA).any((e) => !e.outgoing && e.text.contains('and more text after the key')),
          what: 'alice gets the approved final');
      await until(() => mb.streamsOf(linkB).isEmpty, what: 'bob: approved final replaces the bubble');

      // 4. The run log and turning it off.
      final log = (await mb.daemon.log(linkB, limit: 50)).where((e) => e.action == 'wake').toList();
      print('LOG: ${log.map((e) => e.decision).toList()}');
      expect(log.map((e) => e.decision), containsAll(['ok', 'failed']));
      expect(await mb.wakeOff(linkB), isNull);
      expect(mb.wakeRules, isEmpty);

      // 5. LAN (v5): off by default; only the state is read (the test does not turn on mDNS on the host it runs on).
      await ma.refreshLan();
      print('LAN: enabled ${ma.lan?.enabled}, listening ${ma.lan?.listening}, links ${ma.lan?.links.map((l) => l.contact).toList()}');
      expect(ma.lan?.enabled, isFalse);
      ma.removeListener(watch);
      mb.removeListener(watch);
    } on TimeoutException {
      print('ALICE LOG:\n${alice.log}\nBOB LOG:\n${bob.log}');
      rethrow;
    } finally {
      ma.dispose();
      mb.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null || !hasWake ? 'needs antennad with wake (x-control/4)' : false, timeout: const Timeout(Duration(minutes: 4)));
}
