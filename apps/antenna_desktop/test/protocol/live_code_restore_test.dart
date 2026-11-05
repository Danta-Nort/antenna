// SPDX-License-Identifier: AGPL-3.0-only
// Code mode restore after an update and `agent_watch` (D-103, CONTROL §23) against REAL daemons, a REAL pseudo-terminal
// and the window's REAL hook channel: alice's window starts its agent `helper` (a stand-in for Claude Code that runs
// the hooks of `--settings` as Claude Code does, with a `session_id` in their input, and starts the real `antenna mcp`
// so the token binds to it) with a token file. Then the window goes away as the installer's SIGTERM would take it
// (nothing of its own shutdown runs, the terminal is hung up); a new window comes up without a session and restores the
// agent: the same stand-in with `--resume <the session ID>`, the daemon's token file in its environment, no token in
// its arguments; it types the update line once at the idle prompt and, through `agent_watch`, wakes the agent for a
// message from bob before anyone signs in. A process that is not an ancestor of the agent gets `forbidden`.
//
// Not covered here: the daemon's own `status.updated` (it exists only after a real automatic install, the installer's
// part of D-103); the test gives the new window that fact itself, the one thing it does not read from the daemon.
// Run: ANTENNAD_BIN=<path to antennad> flutter test --tags live test/protocol/live_code_restore_test.dart
@Tags(['live'])
@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/pty.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/claude_state.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/code/terminal_text.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/events.dart';
import '../support/pty_native.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 30), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> untilAsync(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 30), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

const _session = '6b1f0e2c-3d4a-4f5b-8c7d-9e0f1a2b3c4d';

/// A stand-in for Claude Code: its argv goes to `args.log` (one JSON line per start), its environment's token variables
/// to `env.log` (names only); it starts the real `antenna mcp` from `--mcp-config` (the token binds to this process),
/// runs SessionStart, UserPromptSubmit and Stop like Claude Code with `session_id` in their input (the one it resumes,
/// or [_session] written into it), draws an idle prompt, and records every line it reads in `typed.log`.
const _fakeClaude = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
args = sys.argv[1:]
with open('args.log', 'a') as f:
    f.write(json.dumps(args) + '\n')
with open('env.log', 'a') as f:
    f.write(json.dumps(sorted(k for k in os.environ if k.startswith('ANTENNA_'))) + '\n')
session = args[args.index('--resume') + 1] if '--resume' in args else '6b1f0e2c-3d4a-4f5b-8c7d-9e0f1a2b3c4d'
hooks = json.loads(args[args.index('--settings') + 1]).get('hooks', {}) if '--settings' in args else {}
mcp = json.loads(args[args.index('--mcp-config') + 1])['mcpServers']['antenna']
server = subprocess.Popen([mcp['command'], *mcp['args']], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
def run(event, payload):
    for entry in hooks.get(event, []):
        for h in entry.get('hooks', []):
            subprocess.run(['/bin/sh', '-c', h['command']], capture_output=True, text=True,
                           input=json.dumps({'session_id': session, **payload}, separators=(',', ':')))
rule = '─' * 40
def idle():
    sys.stdout.write('\x1b[2J\x1b[H● ready\r\n\r\n' + rule + '\r\n❯ \r\n' + rule + '\r\n  ? for shortcuts\x1b[4;3H')
    sys.stdout.flush()
run('SessionStart', {'hook_event_name': 'SessionStart', 'source': 'resume' if '--resume' in args else 'startup'})
idle()
for line in sys.stdin:
    line = line.rstrip('\n')
    with open('typed.log', 'a') as f:
        f.write(line + '\n')
    run('UserPromptSubmit', {'hook_event_name': 'UserPromptSubmit', 'prompt': line})
    time.sleep(1)
    run('Stop', {'hook_event_name': 'Stop', 'stop_hook_active': False})
    idle()
''';

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final python = ['/usr/bin/python3', '/bin/python3'].where((p) => File(p).existsSync()).firstOrNull;

  test('restored after an update: --resume, the token file, the update line once, a wake through agent_watch',
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
    final argsLog = File('${work.path}/args.log');
    final envLog = File('${work.path}/env.log');
    final alice = XdNode('alice', root, antennad!);
    final bob = XdNode('bob', root, antennad);
    await Future.wait([alice.start(), bob.start()]);
    final a = XControlClient(alice.socket);
    final b = XControlClient(bob.socket);
    // The window settings file, shared by the window before and after the "update".
    final store = Appearance(store: AppearanceStore('${root.path}/window.json'));
    AppModel window() => AppModel(
          connector: XControlClient.new,
          socketPath: alice.socket,
          live: true,
          binaries: CoreBinaries(daemon: antennad, cli: xCli),
          agentRuns: store,
          agentHost: AgentHost(
            startPty: SystemPty.start,
            env: {'HOME': home.path, 'PATH': '${bin.path}:/usr/bin:/bin', 'LANG': 'C.UTF-8'},
            newHooks: () => FileCodeHooks.create('${root.path}/code'),
          ),
        );
    final m1 = window();
    AppModel? m2;
    try {
      await a.init(alice.password);
      await b.init(bob.password);
      await openOwnerSession(a, alice.password);
      await openOwnerSession(b, bob.password);
      try {
        await a.updateAutoStatus();
      } on XControlException catch (e) {
        // Not built yet, or a daemon older than v7 (its strict parser answers `bad_request` to an unknown command).
        if (e.code == XErrorCode.notImplemented ||
            e.code == XErrorCode.unknownCommand ||
            e.code == XErrorCode.badRequest) {
          markTestSkipped('the daemon does not speak x-control/7 yet (${e.code}): run against the D-103 daemon');
          return;
        }
      }
      final inv = Events(a.open(InviteRequest(trust: 3, ttlSecs: 120, label: 'Bob', password: alice.password)));
      final created = await inv.next<InviteCreated>();
      final join = Events(b.open(JoinRequest(
          link: created.link, trust: 3, label: 'alice', connectTimeoutMs: 5000, password: bob.password)));
      final sas = await inv.next<SasEvent>();
      await join.next<NeedInput>((e) => e.isSasCode);
      join.dialog.input(SasCodeInput(sas.code));
      await inv.next<NeedInput>((e) => e.isConfirm);
      inv.dialog.input(ConfirmInput(true, code: sas.code));
      await join.dialog.result;
      await a.agentAdd('helper', localLevel: 0, password: alice.password, links: ['Bob'], everyone: false);

      // 1. The window before the update: the agent starts with a token file ("Restore after an update" is on).
      await m1.connect();
      expect(await m1.login(alice.password), isNull);
      expect(await m1.startAgent(AgentRunSpec(agent: 'helper', cli: AgentCli.claude, workDir: work.path),
          auth: PasswordAuth(alice.password)), isNull);
      final run1 = m1.runOf('helper')!;
      await until(() => run1.claude.state == ClaudeState.idle, what: 'SessionStart').catchError((Object e) {
        print('SCREEN:\n${terminalText(run1.terminal.buffer)}');
        throw e;
      });
      await until(() => store.agentRunRecord('helper')?['session'] == _session, what: 'the session ID recorded');
      final record = store.agentRunRecord('helper')!;
      print('RECORD before: $record');
      final tokenFile = record['token_file']! as String;
      expect(tokenFile, endsWith('/agents/helper.token'));
      expect(File(tokenFile).existsSync(), isTrue);
      expect(json.encode(record), isNot(contains('xat_')));
      expect(jsonDecode(envLog.readAsLinesSync().first), ['ANTENNA_AGENT_TOKEN_FILE', 'ANTENNA_SOCKET']);
      await untilAsync(() async => (await a.agents()).any((x) => x.name == 'helper' && x.boundAlive == true),
          what: 'antenna mcp bound to the stand-in');

      // 2. The installer's SIGTERM: the window process is gone before any of its own code runs; the kernel hangs up the
      // terminal. Here: the model is torn down without the quit question, and the agent's process group is killed.
      final pid = run1.pid!;
      m1.disposeRuns();
      Process.killPid(-pid, ProcessSignal.sighup);
      await untilAsync(() async => !(await a.agents()).any((x) => x.name == 'helper' && x.boundAlive == true),
          what: 'the old binding ended');
      expect(store.agentRunRecord('helper')!['running'], isTrue, reason: 'left set for the restore');
      m1.dispose();

      // 3. The window after the update: no session; the daemon says it came up from an update.
      final w = m2 = window();
      w.daemon.sessionToken = null;
      await w.connect();
      expect(w.phase, Phase.loginRequired);
      w.status = StatusReply(
        state: w.status!.state,
        daemon: w.status!.daemon,
        protocol: w.status!.protocol,
        relay: w.status!.relay,
        links: w.status!.links,
        updated: UpdatedInfo(
            from: '0.1.2', to: '0.1.3', atMs: DateTime.now().millisecondsSinceEpoch, unlocked: true),
      );
      w.restoreAfterUpdate();
      final run2 = w.runOf('helper')!;
      await until(() => argsLog.readAsLinesSync().length >= 2, what: 'the restored stand-in started');
      final argv = (jsonDecode(argsLog.readAsLinesSync().last) as List).cast<String>();
      print('RESTORED argv tail: ${argv.skip(argv.length - 2).toList()}');
      expect(argv.sublist(argv.length - 2), ['--resume', _session]);
      expect(argv.join(' '), isNot(contains('xat_')));
      expect(jsonDecode(envLog.readAsLinesSync().last), ['ANTENNA_AGENT_TOKEN_FILE', 'ANTENNA_SOCKET']);
      await untilAsync(() async => (await a.agents()).any((x) => x.name == 'helper' && x.boundAlive == true),
          what: 'the restored stand-in bound with the token file');
      await until(() => w.watchingAgent('helper'), what: 'agent_watch subscribed without a session');

      // The update line once, at the idle prompt.
      await until(() => typed.existsSync() && typed.readAsLinesSync().isNotEmpty,
              timeout: const Duration(seconds: 30), what: 'the update line')
          .catchError((Object e) {
        print('SCREEN:\n${terminalText(run2.terminal.buffer)}');
        throw e;
      });
      expect(typed.readAsLinesSync(), ['Antenna was updated to 0.1.3: read your inbox and continue.']);

      // A message from bob for helper: the fact comes over agent_watch, the wake line after the rate limit.
      final sw = Stopwatch()..start();
      await b.send('alice', 'helper, status?', address: const MessageAddress.agent('helper'));
      await until(() => typed.readAsLinesSync().length >= 2, timeout: const Duration(seconds: 60), what: 'the wake line');
      print('WOKEN ${sw.elapsedMilliseconds} ms after sending');
      expect(typed.readAsLinesSync().last, 'New Antenna messages from Bob: read your inbox and continue.');

      // Not an ancestor of the agent: forbidden.
      final outsider = await Process.run(python!, [
        '-c',
        'import json,socket,sys\n'
            's=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);f=s.makefile("rw")\n'
            'f.write(json.dumps({"hello":{"proto":"x-control/7","role":"owner"}})+"\\n");f.flush();f.readline()\n'
            'f.write(json.dumps({"req":{"cmd":"agent_watch","agent":"helper"}})+"\\n");f.flush();print(f.readline())',
        alice.socket,
      ]);
      print('OUTSIDER: ${outsider.stdout}');
      expect('${outsider.stdout}', contains('forbidden'));

      // The owner signs in: the watch closes.
      expect(await w.login(alice.password), isNull);
      await until(() => !w.watchingAgent('helper'), what: 'the watch closed after sign-in');
    } finally {
      await m2?.stopAllRuns();
      m2?.dispose();
      await Future.wait([alice.stop(), bob.stop()]);
      await root.delete(recursive: true);
    }
  },
      skip: antennad == null
          ? noXdReason
          : python == null
              ? 'needs python3 for the stand-in'
              : false,
      timeout: const Timeout(Duration(minutes: 4)));
}
