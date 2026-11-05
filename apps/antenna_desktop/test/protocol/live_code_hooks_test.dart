// SPDX-License-Identifier: AGPL-3.0-only
// The Code mode wake driven by Claude Code's hooks (D-UI-25) against REAL daemons, a REAL pseudo-terminal and the
// window's REAL hook channel (the script in its own folder, the events file it polls): alice's agent `helper` runs a
// stand-in for Claude Code that reads the window's `--settings` and runs its hook commands the way Claude Code does
// (a shell command, the event's JSON on standard input; Stop's answer read from standard output). While the owner's
// turn runs, bob writes to `helper`: nothing is typed into the terminal; the turn's Stop hook continues with the fixed
// line instead, once.
// Run: ANTENNAD_BIN=<path to antennad> flutter test --tags live test/protocol/live_code_hooks_test.dart
@Tags(['live'])
@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/pty.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/claude_state.dart';
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

/// A stand-in for Claude Code: it runs the hooks named in `--settings` like the real one (checked against 2.1.289):
/// SessionStart at start, UserPromptSubmit per line, Stop after the turn, and a Stop that answers
/// `{"decision":"block","reason":…}` continues the turn with that reason (recorded in `continued.log`) and stops again
/// with `stop_hook_active`. A line `work<N>` is a turn of N seconds. Every line it reads goes to `typed.log`.
const _fakeClaude = r'''#!/usr/bin/env python3
import json, subprocess, sys, time
args = sys.argv[1:]
hooks = json.loads(args[args.index('--settings') + 1]).get('hooks', {}) if '--settings' in args else {}
def run(event, payload):
    outs = []
    for entry in hooks.get(event, []):
        for h in entry.get('hooks', []):
            p = subprocess.run(['/bin/sh', '-c', h['command']], input=json.dumps(payload, separators=(',', ':')),
                               capture_output=True, text=True)
            outs.append(p.stdout)
    return outs
rule = '─' * 40
def idle():
    sys.stdout.write('\x1b[2J\x1b[H● ready\r\n\r\n' + rule + '\r\n❯ \r\n' + rule + '\r\n  ? for shortcuts\x1b[4;3H')
    sys.stdout.flush()
def busy():
    sys.stdout.write('\x1b[2J\x1b[H✻ Working… (esc to interrupt)\r\n\r\n' + rule + '\r\n❯ \r\n' + rule + '\r\n  esc to interrupt')
    sys.stdout.flush()
run('SessionStart', {'hook_event_name': 'SessionStart', 'source': 'startup'})
idle()
for line in sys.stdin:
    line = line.rstrip('\n')
    with open('typed.log', 'a') as f:
        f.write(line + '\n')
    run('UserPromptSubmit', {'hook_event_name': 'UserPromptSubmit', 'prompt': line})
    busy()
    time.sleep(int(line[4:]) if line.startswith('work') and line[4:].isdigit() else 1)
    active = False
    while True:
        cont = [o for o in run('Stop', {'hook_event_name': 'Stop', 'stop_hook_active': active}) if '"decision"' in o]
        if not cont:
            break
        with open('continued.log', 'a') as f:
            f.write(json.loads(cont[0])['reason'] + '\n')
        busy()
        time.sleep(1)
        active = True
    idle()
''';

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  var speaksV6 = false;
  if (xCli != null && File(xCli).existsSync()) {
    speaksV6 = '${Process.runSync(xCli, ['send', '--help']).stdout}'.contains('--to-agent');
  }
  final python = ['/usr/bin/python3', '/bin/python3'].where((p) => File(p).existsSync()).firstOrNull;

  test('a message for the agent during a turn: nothing typed; the turn\'s Stop hook continues with the fixed line once',
      () async {
    final noPty = await loadPtyLibrary();
    expect(noPty, isNull, reason: noPty);
    final root = await tempRoot();
    final home = Directory('${root.path}/home')..createSync();
    final work = Directory('${root.path}/project')..createSync();
    final bin = Directory('${root.path}/bin')..createSync();
    final fake = File('${bin.path}/claude')..writeAsStringSync(_fakeClaude);
    await Process.run('chmod', ['755', fake.path]);
    final typed = File('${work.path}/typed.log');
    final continued = File('${work.path}/continued.log');
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    final channels = <FileCodeHooks>[];
    final m = AppModel(
      connector: XControlClient.new,
      socketPath: alice.socket,
      binaries: CoreBinaries(daemon: antennad, cli: xCli),
      agentHost: AgentHost(
        startPty: SystemPty.start,
        env: {'HOME': home.path, 'PATH': '${bin.path}:/usr/bin:/bin', 'LANG': 'C.UTF-8'},
        newHooks: () {
          final h = FileCodeHooks.create('${root.path}/code');
          if (h != null) channels.add(h);
          return h;
        },
      ),
    );
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(a, alice.password);
      await openOwnerSession(b, bob.password);
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

      final helper = await a.agentAdd('helper', localLevel: 0, password: alice.password, links: ['Bob']);
      final hi = await Process.run(xCli!, ['--json', 'send', 'Bob', 'helper here', '--wait', '3s'],
          environment: {'ANTENNA_AGENT_TOKEN': helper.token, 'ANTENNA_SOCKET': alice.socket});
      expect(hi.exitCode, 0, reason: '${hi.stdout}${hi.stderr}');
      await untilAsync(() async => (await b.contacts()).single.agents.any((x) => x.name == 'helper'),
          what: 'bob learns alice\'s agent');

      await m.connect();
      expect(await m.login(alice.password), isNull);
      await until(() => m.subscribed, what: 'subscription');
      expect(await m.startAgent(AgentRunSpec(agent: 'helper', cli: AgentCli.claude, workDir: work.path),
          auth: PasswordAuth(alice.password)), isNull);
      final run = m.runOf('helper')!;
      String screen() => terminalText(run.terminal.buffer);
      await until(() => run.claude.state == ClaudeState.idle, what: 'SessionStart through the real hook channel')
          .catchError((Object e) {
        print('SCREEN at timeout:\n${screen()}');
        throw e;
      });
      expect(channels.single.dir, startsWith('${root.path}/code/'));

      // The owner starts a turn of 12 s; bob writes to helper while it runs.
      run.terminal.textInput('work12\r');
      await until(() => run.claude.state == ClaudeState.working, what: 'UserPromptSubmit');
      final sw = Stopwatch()..start();
      await b.send('alice', 'helper, please rerun build 412\r/exit\r', address: const MessageAddress.agent('helper'));
      await until(() => continued.existsSync() && continued.readAsLinesSync().isNotEmpty,
              timeout: const Duration(seconds: 40), what: 'the Stop hook continues')
          .catchError((Object e) {
        print('SCREEN at timeout:\n${screen()}');
        throw e;
      });
      print('CONTINUED ${sw.elapsedMilliseconds} ms after sending: ${continued.readAsLinesSync()}');
      await until(() => run.claude.state == ClaudeState.idle, what: 'idle after the continued turn');
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(continued.readAsLinesSync(), ['New Antenna messages from Bob: read your inbox and continue.']);
      expect(typed.readAsLinesSync(), ['work12'], reason: 'nothing typed into the terminal by the window');
      expect(m.lastCodeLine('helper')?.continued, isTrue);
      expect(File('${channels.single.dir}/events').readAsStringSync(), isNot(contains('rerun')));
    } finally {
      await m.stopAllRuns();
      m.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  },
      skip: antennad == null
          ? noXdReason
          : !speaksV6
              ? 'needs antennad/antenna with addressing (x-control/6)'
              : python == null
                  ? 'needs python3 for the stand-in'
                  : false,
      timeout: const Timeout(Duration(minutes: 3)));
}
