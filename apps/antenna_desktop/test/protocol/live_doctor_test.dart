// SPDX-License-Identifier: AGPL-3.0-only
// The Check panel's daemon facts against a REAL `antennad` (D-UI-26): the keys and the service as the window sees them,
// the relay setting, and a process refused because another program holds the agent's token, read from the real
// `agent_list` (`refused_*`, preview.6). Locked: the panel says so and the link checks wait for the keys.
// Run: ANTENNAD_BIN=<path to antennad> flutter test --tags live test/protocol/live_doctor_test.dart
@Tags(['live'])
@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/doctor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> untilAsync(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  var reportsRefusals = false;
  if (xCli != null && File(xCli).existsSync()) {
    reportsRefusals = '${Process.runSync(xCli, ['doctor', '--help']).stdout}'.isNotEmpty &&
        !'${Process.runSync(xCli, ['doctor', '--help']).stdout}'.contains('not implemented');
  }

  test('real daemon: the service, the keys, the relay setting, and a refused MCP host with who holds the token',
      () async {
    final root = await tempRoot();
    final alice = XdNode('alice', root, antennad!);
    await alice.start();
    final owner = XControlClient(alice.socket);
    final m = AppModel(
      connector: XControlClient.new,
      socketPath: alice.socket,
      live: false,
      binaries: CoreBinaries(daemon: antennad, cli: xCli),
    );
    final procs = <Process>[];
    try {
      await owner.init(alice.password);
      await owner.lock();
      await m.connect();
      await m.runChecks();
      expect(m.checks.whereType<DaemonCheck>().single.state, CheckState.ok);
      expect(m.checks.whereType<KeysCheck>().single.code, 'keys_locked');
      expect(m.checks.whereType<RelayCheck>().single.reason, UnknownReason.locked);

      expect(await m.unlock(alice.password), isNull);
      owner.sessionToken = m.daemon.sessionToken;
      final tok = (await owner.agentAdd('claude', localLevel: 0, password: alice.password)).token;
      // The app: a process that runs `antenna mcp` with the token and keeps it bound.
      final env = {'ANTENNA_AGENT_TOKEN': tok, 'ANTENNA_SOCKET': alice.socket, 'X': xCli!};
      procs.add(await Process.start('/bin/sh', ['-c', r'sleep 60 | "$X" mcp'], environment: env));
      await untilAsync(() async => (await owner.agents()).single.binding?.alive ?? false, what: 'the token bound');
      // Another program with the same token: refused (exit 77), and the daemon keeps the refusal for the owner.
      final other = await Process.start('/bin/sh', ['-c', r'sleep 1 | "$X" mcp 2>/dev/null; echo "rc=$?"; sleep 30'],
          environment: env);
      procs.add(other);
      final rc = Completer<String>();
      other.stdout.listen((b) {
        final s = String.fromCharCodes(b);
        if (s.contains('rc=') && !rc.isCompleted) rc.complete(s.trim());
      });
      expect(await rc.future.timeout(const Duration(seconds: 20)), 'rc=77');

      await m.runChecks();
      expect(m.checks.whereType<KeysCheck>().single.state, CheckState.ok);
      final relay = m.checks.whereType<RelayCheck>().single;
      expect((relay.setting, relay.disabled, relay.state), ('disabled', true, CheckState.info),
          reason: 'the test daemons run without a relay and have no level 1–2 contacts');
      final tokens = m.checks.whereType<TokenCheck>().single;
      print('TOKENS: ${tokens.refusals.map((r) => '${r.agent} held by ${r.boundComm}/${r.boundPid}, refused '
          '${r.refusedComm}/${r.refusedPid} alive=${r.refusedAlive}')}');
      expect(tokens.code, 'token_bound_elsewhere');
      final r = tokens.refusals.single;
      // The hosts run `/bin/sh`; on macOS /bin/sh is a copy of bash, so the process `comm` is `bash`, not `sh`.
      final shComm = Platform.isMacOS ? 'bash' : 'sh';
      expect((r.agent, r.refusedPid, r.refusedComm, r.refusedAlive, r.boundComm),
          ('claude', other.pid, shComm, true, shComm));
    } finally {
      for (final p in procs) {
        p.kill(ProcessSignal.sigkill);
      }
      m.dispose();
      await alice.stop();
      await root.delete(recursive: true);
    }
  },
      skip: antennad == null
          ? noXdReason
          : !reportsRefusals
              ? 'needs antennad/antenna from 0.1.0-preview.6 (refused MCP hosts, antenna doctor)'
              : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
