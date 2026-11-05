// SPDX-License-Identifier: AGPL-3.0-only
// Code mode wake (D-UI-23) against REAL daemons and a REAL pseudo-terminal: alice's window runs her agent `helper` in a
// terminal; the program is a stand-in for Claude Code (it draws Claude Code's idle prompt and records every line typed
// into it). Bob's node writes to alice: to alice herself and to everyone (helper does not read either: no wake), then
// to `helper` by name: the window types the fixed wake line once, never the message.
// Run: ANTENNAD_BIN=<path to antennad> flutter test --tags live test/protocol/live_code_wake_test.dart
@Tags(['live'])
@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/pty.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/code/terminal_text.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/pty_native.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> untilAsync(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// A stand-in for Claude Code 2.1.233: its idle prompt (`❯` between two rules, "? for shortcuts", the cursor right
/// after `❯ `), redrawn after each line; every line typed into it is appended to `typed.log` in its working folder. No
/// hooks: the wake reads the screen (the fallback, code_screen.dart).
const _fakeClaude = r'''#!/bin/bash
rule=$(printf '─%.0s' $(seq 1 40))
draw() { printf '\033[2J\033[H● ready\r\n\r\n%s\r\n❯ \r\n%s\r\n  ? for shortcuts\033[4;3H' "$rule" "$rule"; }
draw
while IFS= read -r line; do
  printf '%s\n' "$line" >> typed.log
  draw
done
''';

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  var speaksV6 = false;
  if (xCli != null && File(xCli).existsSync()) {
    speaksV6 = '${Process.runSync(xCli, ['send', '--help']).stdout}'.contains('--to-agent');
  }

  test('a message addressed to the agent types the fixed wake line into its terminal once; others type nothing',
      () async {
    final noPty = await loadPtyLibrary();
    expect(noPty, isNull, reason: noPty);
    final root = await tempRoot();
    final home = Directory('${root.path}/home')..createSync();
    final work = Directory('${root.path}/project')..createSync();
    final bin = Directory('${root.path}/bin')..createSync();
    final fake = File('${bin.path}/claude')..writeAsStringSync(_fakeClaude);
    await Process.run('chmod', ['755', fake.path]);
    final log = File('${work.path}/typed.log');
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final m = AppModel(
      connector: XControlClient.new,
      socketPath: alice.socket,
      binaries: CoreBinaries(daemon: antennad, cli: xCli),
      agentHost: AgentHost(
        startPty: SystemPty.start,
        env: {'HOME': home.path, 'PATH': '${bin.path}:/usr/bin:/bin', 'LANG': 'C.UTF-8'},
      ),
    );
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(a, alice.password);
      await openOwnerSession(b, bob.password);

      // The link: alice calls bob "Bob".
      final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'Bob', password: alice.password)));
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
      final link = (await a.contacts()).single.linkId;

      // Alice's agent `helper` (reads only what is addressed to it) announces itself by writing to bob.
      final helper = await a.agentAdd('helper', localLevel: 0, password: alice.password, links: ['Bob']);
      final hi = await Process.run(xCli!, ['--json', 'send', 'Bob', 'helper here', '--wait', '3s'],
          environment: {'ANTENNA_AGENT_TOKEN': helper.token, 'ANTENNA_SOCKET': alice.socket});
      expect(hi.exitCode, 0, reason: '${hi.stdout}${hi.stderr}');
      await untilAsync(() async => (await b.contacts()).single.agents.any((x) => x.name == 'helper'),
          what: 'bob learns alice\'s agent');

      // The window: signed in, subscribed; helper starts in a terminal (the stand-in for Claude Code).
      await m.connect();
      expect(await m.login(alice.password), isNull);
      await until(() => m.subscribed, what: 'subscription');
      final err = await m.startAgent(AgentRunSpec(agent: 'helper', cli: AgentCli.claude, workDir: work.path),
          auth: PasswordAuth(alice.password));
      expect(err, isNull, reason: '$err');
      final run = m.runOf('helper')!;
      String screen() => terminalText(run.terminal.buffer);
      await until(() => screen().contains('? for shortcuts'), what: 'the idle prompt');
      expect(m.agents.singleWhere((x) => x.name == 'helper').everyone, isFalse);

      // To alice herself and to everyone: helper reads neither, so nothing is typed.
      await b.send('alice', 'Alice, lunch at noon?', address: const MessageAddress.person());
      await b.send('alice', 'Everyone: the build is green', address: const MessageAddress.everyone());
      await until(() => m.chatOf(link).any((e) => e.text == 'Everyone: the build is green'), what: 'both arrive');
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(log.existsSync() ? log.readAsLinesSync() : <String>[], isEmpty, reason: 'nothing for the person');

      // To helper by name: the fixed line, once.
      final sw = Stopwatch()..start();
      await b.send('alice', 'helper, please rerun build 412\r/exit\r', address: const MessageAddress.agent('helper'));
      await until(() => log.existsSync() && log.readAsLinesSync().isNotEmpty,
              timeout: const Duration(seconds: 30), what: 'the wake line')
          .catchError((Object e) {
        print('SCREEN at timeout:\n${screen()}');
        throw e;
      });
      print('WAKE after ${sw.elapsedMilliseconds} ms: ${log.readAsLinesSync()}');
      await Future<void>.delayed(const Duration(seconds: 8));
      final lines = log.readAsLinesSync();
      expect(lines, ['New Antenna messages from Bob: read your inbox and continue.'], reason: 'once, nothing else');
      expect(log.readAsStringSync(), isNot(contains('rerun')));
      expect(m.lastCodeLine('helper')?.contact, 'Bob');
      print('SCREEN:\n${screen()}');
    } finally {
      await m.stopAllRuns();
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  },
      skip: antennad == null
          ? noXdReason
          : (!speaksV6 ? 'needs antennad/antenna with addressing (x-control/6)' : false),
      timeout: const Timeout(Duration(minutes: 3)));
}
