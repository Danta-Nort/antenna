// SPDX-License-Identifier: AGPL-3.0-only
// Code mode against a REAL `antennad`, a REAL pseudo-terminal (flutter_pty's C code, built for the test) and the real
// `antenna` CLI: "Start agent" creates the agent with the owner password, starts a command in the terminal with the
// token in its environment only, the output reaches the terminal, and the daemon sees the command's process tree as the
// agent: `antenna mcp` binds the token to the agent's own process (not the terminal's session leader, D-28), the
// window stays the owner, Stop ends the binding. A negative control starts `antenna mcp` under a session leader
// without the wrapper: the daemon refuses to bind.
// Run: ANTENNAD_BIN=<path to antennad> flutter test test/protocol/live_code_mode_test.dart
@Tags(['live'])
@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/program_locator.dart';
import 'package:antenna_desktop/host/pty.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/code/terminal_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart' show TerminalKey;

import '../support/pty_native.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<void> untilAsync(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 20), String what = ''}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// (comm, ppid, sid) of a process; `null` if it is gone.
(String, int, int)? procStatOf(int pid) {
  try {
    return procStat(pid);
  } on FileSystemException {
    return null;
  }
}

/// (comm, ppid, sid): from `/proc/<pid>/stat` on Linux; from `ps` plus `getsid(2)` (via python3) on macOS, which has
/// no `/proc`. `comm` is the short accounting name on both (Linux's stat field, macOS's `ucomm`).
(String, int, int) procStat(int pid) {
  if (Platform.isLinux) {
    final s = File('/proc/$pid/stat').readAsStringSync();
    final comm = s.substring(s.indexOf('(') + 1, s.lastIndexOf(')'));
    final f = s.substring(s.lastIndexOf(')') + 2).split(' ');
    return (comm, int.parse(f[1]), int.parse(f[3]));
  }
  final ps = Process.runSync('ps', ['-p', '$pid', '-o', 'ucomm=,ppid=']);
  final line = '${ps.stdout}'.trim();
  if (ps.exitCode != 0 || line.isEmpty) throw FileSystemException('no such process', 'ps -p $pid');
  final parts = line.split(RegExp(r'\s+'));
  final sid = Process.runSync('python3', ['-c', 'import os,sys; print(os.getsid(int(sys.argv[1])))', '$pid']);
  if (sid.exitCode != 0) throw FileSystemException('no such process', 'getsid $pid');
  return (parts.first, int.parse(parts[1]), int.parse('${sid.stdout}'.trim()));
}

/// (argv, env) of a process: from `/proc/<pid>/{cmdline,environ}` on Linux; from `ps` on macOS. On macOS the env is
/// split on spaces (good enough for the checks here: a token value has none), and `ps -E` appends it after the argv.
(List<String>, List<String>) procArgvEnv(int pid) {
  if (Platform.isLinux) {
    return (
      File('/proc/$pid/cmdline').readAsStringSync().split('\u0000'),
      File('/proc/$pid/environ').readAsStringSync().split('\u0000'),
    );
  }
  final argv = '${Process.runSync('ps', ['-ww', '-o', 'command=', '-p', '$pid']).stdout}'.trimRight();
  final both = '${Process.runSync('ps', ['-Eww', '-o', 'command=', '-p', '$pid']).stdout}'.trimRight();
  final envStr = both.length > argv.length ? both.substring(argv.length) : '';
  return (argv.split(RegExp(r'\s+')), envStr.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList());
}

String screen(AgentRun r) => terminalText(r.terminal.buffer);

/// Processes of the session [sid] (the terminal's session: the wrapper and everything it started). Linux walks
/// `/proc`; macOS lists every pid with `ps` and keeps those whose `getsid(2)` is [sid].
List<int> sessionMembers(int sid) {
  if (Platform.isLinux) {
    return [
      for (final d in Directory('/proc').listSync().whereType<Directory>())
        if (int.tryParse(d.path.split('/').last) case final pid?)
          if (procStatOf(pid)?.$3 == sid) pid,
    ];
  }
  final pids = '${Process.runSync('ps', ['-axo', 'pid=']).stdout}'
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final r = Process.runSync('python3', [
    '-c',
    'import os,sys\nsid=int(sys.argv[1])\nfor a in sys.argv[2:]:\n try:\n  p=int(a)\n  if os.getsid(p)==sid: print(p)\n except Exception: pass',
    '$sid',
    ...pids,
  ]);
  return '${r.stdout}'.split('\n').map((s) => int.tryParse(s.trim())).whereType<int>().toList();
}

void main() {
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';

  test('an agent started in the window terminal is the agent for the daemon; the window stays the owner', () async {
    final noPty = await loadPtyLibrary();
    expect(noPty, isNull, reason: noPty);
    final root = await tempRoot();
    final home = Directory('${root.path}/home')..createSync();
    final work = Directory('${root.path}/project')..createSync();
    final alice = XdNode('alice', root, antennad!);
    await alice.start();
    final owner = XControlClient(alice.socket);
    final m = AppModel(
      connector: XControlClient.new,
      socketPath: alice.socket,
      live: false,
      binaries: CoreBinaries(daemon: antennad, cli: xCli),
      agentHost: AgentHost(
        startPty: SystemPty.start,
        env: {'HOME': home.path, 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'},
      ),
    );
    try {
      await owner.init(alice.password);
      await m.connect();
      expect(await m.login(alice.password), isNull);
      expect(m.phase, Phase.unlocked);
      owner.sessionToken = m.daemon.sessionToken;

      // "Start agent" → New agent, own command. `antenna` by its absolute path: a login bash resets PATH.
      // List the shell's own numeric descriptors. Linux has /proc/$$/fd; macOS has only /dev/fd, which also reports the
      // directory descriptor the listing opens, so directory entries are skipped (see agent_launch_test).
      final listFds = r'for d in /proc/$$/fd /dev/fd; do test -d "$d" || continue; '
          r'for f in "$d"/*; do test -e "$f" || continue; test -d "$f" && continue; echo "${f##*/}"; done; break; done';
      final cmd = 'bash -lc "echo hello; $xCli --version; echo FD-BEGIN; $listFds; echo FD-END; '
          '$xCli --json session; $xCli mcp < <(sleep 600) & wait"';
      final sw = Stopwatch()..start();
      final err = await m.startAgent(
        AgentRunSpec(agent: 'jarvis', cli: AgentCli.custom, workDir: work.path, command: cmd),
        auth: PasswordAuth(alice.password),
        create: const NewAgent(name: 'jarvis', localLevel: 3),
      );
      expect(err, isNull, reason: '$err');
      final run = m.runOf('jarvis')!;
      expect(run.state, AgentRunState.running);
      await until(() => screen(run).contains('"agent"'), what: 'the session reply in the terminal');
      final text = screen(run);
      print('TERMINAL (${sw.elapsedMilliseconds} ms):\n$text');
      expect(text, contains('hello'));
      expect(text, contains('antenna 0.'), reason: '`antenna --version` printed in the terminal');
      // The token in the environment makes `antenna` the agent: `session` exists only for agents.
      expect(text.replaceAll('\n', ''), contains('"agent":"jarvis"'));
      // The wrapper closed the window's descriptors: the agent's shell has only the terminal.
      final fds = text.substring(text.indexOf('FD-BEGIN') + 8, text.indexOf('FD-END')).trim().split(RegExp(r'\s+'));
      expect(fds, ['0', '1', '2'], reason: 'descriptors inherited by the agent');

      // `antenna mcp` bound the token to its parent, the agent's bash: not the terminal's session leader.
      AgentInfo? jarvis;
      Future<String?> boundTo() async {
        jarvis = (await owner.agents()).firstWhere((a) => a.name == 'jarvis');
        final b = jarvis!.boundTo;
        return b == null || b.endsWith('(ended)') ? null : b;
      }

      await untilAsync(() async => await boundTo() != null, what: 'the token bound to the agent process');
      print('BOUND ${jarvis!.boundTo}; terminal session leader ${run.pid} ${procStat(run.pid!)}');
      final anchor = int.parse(jarvis!.boundTo!.split(' ').first);
      final (comm, ppid, sid) = procStat(anchor);
      expect(comm, 'bash');
      expect(ppid, run.pid, reason: 'the anchor is the wrapper\'s child');
      expect(sid, run.pid, reason: 'the wrapper is the session leader of the terminal');
      expect(anchor, isNot(run.pid), reason: 'a session leader is never an anchor (D-28)');
      // The window (an ancestor of the anchor) is still the owner.
      expect((await owner.hello()).role, 'owner');
      expect((await m.daemon.hello()).role, 'owner');

      // Restart: a new process, the same token from memory (no password), bound again.
      final firstPid = run.pid;
      expect(m.hasAgentToken('jarvis'), isTrue);
      expect(await m.restartRun(run), isNull);
      expect(run.pid, isNot(firstPid));
      await untilAsync(() async {
        final b = await boundTo();
        return b != null && procStatOf(int.parse(b.split(' ').first))?.$2 == run.pid;
      }, what: 'bound again after the restart');
      print('BOUND after restart: ${jarvis!.boundTo}');

      // Stop: SIGHUP to the terminal's process group; the binding ends with the process, and nothing of the
      // terminal's session is left (no orphans: the agent's shell, `antenna mcp`, the `sleep`).
      final session = run.pid!;
      expect(sessionMembers(session), hasLength(greaterThanOrEqualTo(3)));
      final t0 = sw.elapsedMilliseconds;
      await m.stopRun(run);
      expect(run.state, AgentRunState.exited);
      expect(run.stoppedByOwner, isTrue);
      print('STOP took ${sw.elapsedMilliseconds - t0} ms, exit code ${run.exitCode}');
      await until(() => sessionMembers(session).isEmpty, timeout: const Duration(seconds: 5), what: 'no orphans');
      jarvis = (await owner.agents()).firstWhere((a) => a.name == 'jarvis');
      expect(jarvis!.boundTo, anyOf(isNull, endsWith('(ended)')));

      // The exit code comes from the wrapper even though this test process has other children (the daemon), whose
      // presence makes the Dart VM reap the terminal's process before flutter_pty can (TROUBLESHOOTING "Code mode").
      expect(
        await m.startAgent(
          AgentRunSpec(agent: 'jarvis', cli: AgentCli.custom, workDir: work.path, command: "bash -c 'echo bye; exit 3'"),
        ),
        isNull,
      );
      expect(identical(m.runOf('jarvis'), run), isTrue, reason: 'the same tab is reused');
      await until(() => run.state == AgentRunState.exited, what: 'the second command ends');
      expect(run.exitCode, 3);
      expect(run.stoppedByOwner, isFalse);
      expect(screen(run), contains('bye'));

      // Negative control: `antenna mcp` whose parent is the terminal's session leader (no wrapper) is refused.
      final ctl = await owner.agentAdd('control', localLevel: 0, password: alice.password);
      final bare = SystemPty.start(
        AgentLaunch(
          executable: '/bin/bash',
          arguments: ['-c', '$xCli mcp < /dev/null; echo "MCP-EXIT=\$?"; sleep 0.2'],
          environment: {'ANTENNA_AGENT_TOKEN': ctl.token, 'ANTENNA_SOCKET': alice.socket},
          workingDirectory: work.path,
          command: const [],
        ),
        rows: 24,
        columns: 200,
      );
      final out = StringBuffer();
      bare.output.listen((b) => out.write(String.fromCharCodes(b)));
      final code = await bare.exitCode.timeout(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      print('NEGATIVE CONTROL (exit $code): $out');
      expect('$out', contains('cannot bind the token'));
      expect('$out', isNot(contains('MCP-EXIT=0')));
    } finally {
      await m.stopAllRuns();
      m.dispose();
      await alice.stop();
      await root.delete(recursive: true);
    }
  }, skip: antennad == null ? noXdReason : false, timeout: const Timeout(Duration(minutes: 2)));

  // The real Claude Code, if this computer has it: the flags the window passes (`--mcp-config` with the Antenna server,
  // `--strict-mcp-config`, `--settings` with the hooks) are accepted, Claude Code starts `antenna mcp` with the token
  // from its environment, and the daemon binds the token to the `claude` process. No sign-in is needed for that (an
  // empty HOME: Claude Code shows its first-run screen; the MCP server starts anyway).
  final claude = ProgramLocator(env: Platform.environment).locate(AgentCli.claude.binary);
  test('real Claude Code in the window terminal: the MCP server binds to claude, the token is not in its arguments',
      () async {
    final noPty = await loadPtyLibrary();
    expect(noPty, isNull, reason: noPty);
    final root = await tempRoot();
    final home = Directory('${root.path}/home')..createSync();
    final work = Directory('${root.path}/project')..createSync();
    final alice = XdNode('alice', root, antennad!);
    await alice.start();
    final owner = XControlClient(alice.socket);
    final m = AppModel(
      connector: XControlClient.new,
      socketPath: alice.socket,
      live: false,
      binaries: CoreBinaries(daemon: antennad, cli: xCli),
      agentHost: AgentHost(
        startPty: SystemPty.start,
        env: {'HOME': home.path, 'PATH': '${File(claude!).parent.path}:/usr/bin:/bin', 'LANG': 'C.UTF-8'},
      ),
    );
    try {
      await owner.init(alice.password);
      await m.connect();
      expect(await m.login(alice.password), isNull);
      owner.sessionToken = m.daemon.sessionToken;
      final err = await m.startAgent(
        AgentRunSpec(agent: 'claude-dev', cli: AgentCli.claude, workDir: work.path),
        auth: PasswordAuth(alice.password),
        create: const NewAgent(name: 'claude-dev', localLevel: 5),
      );
      expect(err, isNull, reason: '$err');
      final run = m.runOf('claude-dev')!;
      // Claude Code asks first whether the folder is trusted; Enter accepts (typed into the terminal like a person).
      // Since 2.1.289 a new HOME gets the first-run screens (text style, then the sign-in) before any of that, and
      // no MCP server starts until someone signs in: nothing left to check here then.
      bool firstRun() => screen(run).contains('Choose the text style') || screen(run).contains('Select login method');
      await until(() => screen(run).contains('trust this folder') || firstRun(), timeout: const Duration(seconds: 30),
          what: 'the folder trust question').catchError((Object e) {
        print('SCREEN at timeout:\n${screen(run)}');
        throw e;
      });
      if (firstRun()) {
        markTestSkipped('this Claude Code asks for sign-in in a new HOME before it starts MCP servers');
        return;
      }
      // 2.1.233 preselected "Yes"; 2.1.289 preselects "No, exit" and lists "Yes, I trust this folder" second.
      if (screen(run).contains('❯ No, exit')) {
        await Future<void>.delayed(const Duration(seconds: 1));
        run.terminal.keyInput(TerminalKey.arrowDown);
        await until(() => screen(run).contains('❯ Yes, I trust this folder'), what: 'Yes selected');
      }
      run.terminal.textInput('\r');
      String? bound;
      await untilAsync(() async {
        final a = (await owner.agents()).firstWhere((a) => a.name == 'claude-dev');
        bound = a.boundTo;
        return bound != null && !bound!.endsWith('(ended)');
      }, timeout: const Duration(seconds: 40), what: 'antenna mcp started by Claude Code and bound').catchError((Object e) {
        print('SCREEN at timeout:\n${screen(run)}');
        throw e;
      });
      final pid = int.parse(bound!.split(' ').first);
      final (comm, ppid, sid) = procStat(pid);
      final (argv, env) = procArgvEnv(pid);
      print('CLAUDE bound: $bound; ppid $ppid (wrapper ${run.pid}), sid $sid; argv[0..1] ${argv.take(2).toList()}');
      expect(ppid, run.pid, reason: 'claude is the wrapper\'s child, not the session leader');
      expect(comm, isNot('bash'));
      expect(argv.join(' '), contains('--strict-mcp-config'));
      expect(argv.join(' '), isNot(contains('xat_')), reason: 'the token must not be in the arguments');
      expect(env.any((e) => e.startsWith('ANTENNA_AGENT_TOKEN=xat_')), isTrue, reason: 'the token is in the environment');
      print('SCREEN:\n${screen(run).split('\n').take(12).join('\n')}');
      await m.stopRun(run);
      await until(() => sessionMembers(run.pid!).isEmpty, timeout: const Duration(seconds: 5), what: 'no orphans');
    } finally {
      await m.stopAllRuns();
      m.dispose();
      await alice.stop();
      await root.delete(recursive: true);
    }
  },
      skip: antennad == null
          ? noXdReason
          : claude == null
              ? 'Claude Code (`claude`) is not installed here'
              : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
