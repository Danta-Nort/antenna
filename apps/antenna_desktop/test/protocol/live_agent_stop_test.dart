// SPDX-License-Identifier: AGPL-3.0-only
// The stop switch and urgent messages (x-control/7, CONTROL §33; experimental) through the window's own protocol
// client against REAL daemons: `agent_terminal` takes only a session leader this client started; `agent_stop` sweeps
// that session whole (the command a shell runs there, and with it the shell) and says so; an own computer stops
// another's agent with `device_agent_stop`, and the agent event there says who asked; `devices[].stop_agents`,
// `contacts[].peer_urgent`; an urgent message to an own computer's agent goes with the flag, the receiving daemon marks
// it urgent (and only once per agent per 30 s), and urgent is refused below ∞ and without an agent. Skipped cleanly
// with a daemon from before the switch (`agent_stop` unknown).
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_agent_stop_test.dart
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Matcher _refused() => isA<XControlException>();

Future<void> _until(Future<bool> Function() cond,
    {Duration timeout = const Duration(seconds: 30), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<void> _pair(XControlClient a, XdNode an, XControlClient b, XdNode bn, int trust) async {
  final inv = Events(a.open(InviteRequest(trust: trust, ttlSecs: 120, label: bn.name, password: an.password)));
  final created = await inv.next<InviteCreated>();
  final join = Events(b.open(JoinRequest(
    link: created.link,
    trust: trust,
    label: an.name,
    connectTimeoutMs: 5000,
    password: bn.password,
  )));
  final sas = await inv.next<SasEvent>();
  await join.next<NeedInput>((e) => e.isSasCode);
  join.dialog.input(SasCodeInput(sas.code));
  await inv.next<NeedInput>((e) => e.isConfirm);
  inv.dialog.input(ConfirmInput(true, code: sas.code));
  await join.dialog.result;
}

/// A terminal session this test started, as the window's wrapper is: a shell that leads its own session (`setsid`
/// execs in place, so the PID is the child's) and runs a command under it. macOS has no `setsid` program; perl's
/// POSIX::setsid then exec does the same.
Future<Process> _session() => Platform.isMacOS
    ? Process.start('perl', [
        '-MPOSIX',
        '-e',
        r'POSIX::setsid() or die "setsid: $!"; exec @ARGV',
        'sh',
        '-c',
        'sleep 300 & wait',
      ])
    : Process.start('setsid', ['sh', '-c', 'sleep 300 & wait']);

bool _alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

/// The daemon knows the stop switch (`agent_stop` with an unknown agent is `not_found`, not an unknown command).
Future<String?> _noSwitch(XControlClient c) async {
  try {
    await c.agentStop('no-such-agent');
  } on XControlException catch (e) {
    if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest) {
      return 'needs antennad with the stop switch (x-control/7, `agent_stop`): ${e.code} ${e.message}';
    }
  }
  return null;
}

void main() {
  final antennad = findXd();

  test('agent_terminal takes only our own session leader; agent_stop sweeps that session whole', () async {
    final root = await tempRoot();
    final node = XdNode('mini', root, antennad!);
    await node.start();
    final c = XControlClient(node.socket);
    Process? lone;
    Process? session;
    try {
      await c.init(node.password);
      await openOwnerSession(c, node.password);
      if (await _noSwitch(c) case final why?) {
        markTestSkipped(why);
        return;
      }
      await c.agentAdd('helper', localLevel: 3, password: node.password);

      // Not ours, or not a session leader: refused (the window ignores the error; nothing is noted).
      await expectLater(c.agentTerminal('helper', 1), throwsA(_refused()));
      lone = await Process.start('sleep', ['300']);
      await expectLater(c.agentTerminal('helper', lone.pid), throwsA(_refused()), reason: 'not a session leader');

      session = await _session();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await c.agentTerminal('helper', session.pid);
      final sw = Stopwatch()..start();
      final r = await c.agentStop('helper');
      print('agent_stop: how=${r.how} processes=${r.processes} left=${r.left} names=${r.names} '
          'in ${sw.elapsedMilliseconds} ms');
      expect(r.agent, 'helper');
      expect(r.how, StopHow.terminal);
      expect(r.processes, greaterThanOrEqualTo(1), reason: 'the command the session runs');
      expect(r.left, 0);
      expect(r.names, contains('sleep'));
      // The whole session ends: the command under the shell, and with it the shell that leads it.
      await session.exitCode.timeout(const Duration(seconds: 10));
      expect(_alive(lone.pid), isTrue, reason: 'a process outside the session is not touched');

      // Nothing runs any more: the next stop says so.
      final again = await c.agentStop('helper');
      expect(again.how, StopHow.none);
      await expectLater(c.agentStop('no-such-agent'), throwsA(_refused()));
    } finally {
      lone?.kill(ProcessSignal.sigkill);
      session?.kill(ProcessSignal.sigkill);
      await node.stop();
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 2)));

  test('own computers: urgent messages to an agent, and a stop asked from the other computer', () async {
    final root = await tempRoot();
    final mini = XdNode('mini', root, antennad!);
    final lap = XdNode('lap', root, antennad);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([mini.start(), lap.start(), bob.start()]);
    final c = XControlClient(mini.socket);
    final l = XControlClient(lap.socket);
    final b = XControlClient(bob.socket);
    Process? session;
    try {
      await Future.wait([c.init(mini.password), l.init(lap.password), b.init(bob.password)]);
      await openOwnerSession(c, mini.password);
      await openOwnerSession(l, lap.password);
      await openOwnerSession(b, bob.password);
      if (await _noSwitch(l) case final why?) {
        markTestSkipped(why);
        return;
      }
      await _pair(c, mini, l, lap, 5);
      await _pair(l, lap, b, bob, 3);
      await c.agentAdd('helper', localLevel: 3, password: mini.password);
      final watch = Events(c.subscribe());
      await watch.next<Subscribed>();

      // The laptop learns that the mini takes urgent messages and stops its agents on request.
      await _until(() async => (await l.contacts()).firstWhere((x) => x.label == 'mini').peerUrgent,
          what: 'peer_urgent of the mini');
      await _until(() async {
        final d = expectReply<DevicesReply>(await l.call(const DevicesRequest()));
        return d.devices.where((x) => x.contact == 'mini').firstOrNull?.stopAgents ?? false;
      }, what: 'stop_agents of the mini');

      // Urgent to the mini's agent: the flag goes, and the mini's daemon marks it.
      final sent =
          await l.send('mini', 'Stop the deploy now', address: const MessageAddress.agent('helper'), urgent: true);
      expect(sent.urgent, isTrue);
      final got = await watch.next<MessageEvent>((e) => e.message.text == 'Stop the deploy now');
      expect(got.message.urgent, isTrue);
      final mine = (await l.history('mini')).messages.firstWhere((h) => h.text == 'Stop the deploy now');
      expect(mine.urgent, isTrue, reason: 'outgoing: sent with the flag');
      // A second within 30 s: delivered, but not urgent on the mini.
      await l.send('mini', 'and the staging one', address: const MessageAddress.agent('helper'), urgent: true);
      final second = await watch.next<MessageEvent>((e) => e.message.text == 'and the staging one');
      expect(second.message.urgent, isFalse, reason: 'at most one urgent message per agent per 30 s');
      // A normal message is never urgent.
      await l.send('mini', 'thanks', address: const MessageAddress.agent('helper'));
      expect((await watch.next<MessageEvent>((e) => e.message.text == 'thanks')).message.urgent, isFalse);
      // Refused: below ∞, and without an agent.
      await expectLater(l.send('bob', 'x', address: const MessageAddress.agent('helper'), urgent: true),
          throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.forbidden)));
      await expectLater(l.send('mini', 'x', address: const MessageAddress.person(), urgent: true),
          throwsA(isA<XControlException>().having((e) => e.code, 'code', XErrorCode.badRequest)));

      // The laptop stops the mini's agent: the mini sweeps the session it was told about.
      session = await _session();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await c.agentTerminal('helper', session.pid);
      final r = await l.deviceAgentStop('mini', 'helper');
      print('device_agent_stop: contact=${r.contact} how=${r.how} processes=${r.processes} names=${r.names}');
      expect((r.contact, r.agent, r.how), ('mini', 'helper', StopHow.terminal));
      expect(r.processes, greaterThanOrEqualTo(1));
      await session.exitCode.timeout(const Duration(seconds: 10));
      final ev = await watch.next<AgentEvent>((e) => e.name == 'helper' && e.change == 'stopped');
      expect(ev.by, 'lap', reason: 'the mini names the computer that asked by its own label for it');
      // Bob is no own computer: refused.
      await expectLater(l.deviceAgentStop('bob', 'helper'), throwsA(_refused()));
      await watch.close();
    } finally {
      session?.kill(ProcessSignal.sigkill);
      await Future.wait([mini.stop(), lap.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 3)));
}
