// SPDX-License-Identifier: AGPL-3.0-only
// The agents' questions (D-118) against a REAL `antennad`: the agent asks with the agent CLI; the window's model lists
// the question and gets the subscription's `escalation` event, answers it, and the agent's `wait` returns the answer
// once; where an agent's questions go is set with the password and shows in the agent list.
// Run: ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live test/protocol/live_questions_test.dart
@Tags(['live'])
@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/xd_harness.dart';

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  var hasQuestions = false;
  if (xCli != null && File(xCli).existsSync()) {
    hasQuestions = '${Process.runSync(xCli, ['--help']).stdout}'.contains('questions');
  }

  test('real daemon: a question from the agent CLI reaches the window, the answer reaches the agent once', () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    await alice.start();
    final owner = XControlClient(alice.socket);
    final m = AppModel(
      connector: XControlClient.new,
      socketPath: alice.socket,
      binaries: CoreBinaries(daemon: antennad, cli: xCli),
    );
    try {
      await owner.init(alice.password);
      await m.connect();
      expect(await m.login(alice.password), isNull);
      await until(() => m.subscribed, what: 'subscription');
      owner.sessionToken = m.daemon.sessionToken;
      final tok = (await owner.agentAdd('claude', localLevel: 0, password: alice.password)).token;
      final env = {'ANTENNA_AGENT_TOKEN': tok, 'ANTENNA_SOCKET': alice.socket};
      Future<Map<String, Object?>> agent(List<String> args) async {
        final r = await Process.run(xCli!, ['--json', ...args], environment: env);
        final out = '${r.stdout}'.trim();
        return json.decode(out.isEmpty ? '{}' : out.split('\n').last) as Map<String, Object?>;
      }

      final asked = await agent(['escalate', 'Should I rotate the staging keys today?']);
      expect(asked['state'], 'open', reason: '$asked');
      await until(() => m.questions.isNotEmpty, what: 'the escalation event');
      expect(m.questions.single.question, 'Should I rotate the staging keys today?');
      expect(m.questions.single.agent, 'claude');

      expect(await m.answerQuestion(m.questions.single.id, 'Yes, after 18:00.'), isNull);
      expect(m.questions, isEmpty);
      final w = await agent(['wait', '--timeout', '5s']);
      final got = (w['escalations']! as List).single as Map<String, Object?>;
      expect((got['state'], got['answer']), ('answered', 'Yes, after 18:00.'));
      final again = await agent(['wait', '--timeout', '1s']);
      expect(again['escalations'], isNull, reason: 'given once');

      // Where its questions go: a contact needs one among its links; back to the owner
      expect(await m.setAgentEscalate('claude', PasswordAuth(alice.password)), isNull);
      await m.refreshAgents();
      expect(m.agents.single.escalateTo, isNull);
    } finally {
      m.dispose();
      await alice.stop();
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : (hasQuestions ? false : 'this antenna has no questions yet'));
}
