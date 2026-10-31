// SPDX-License-Identifier: AGPL-3.0-only
// The Claude Code canary (tools/claude-canary.sh): the Code mode wake (D-UI-23, D-UI-25) against the REAL Claude Code
// installed on this computer, whatever version it has updated itself to. Claude Code changes its screen, and sometimes
// its behaviour, from one release to the next; a daily run of this test says whether the wake still works with the
// newest one and, if not, at which step it broke. Everything goes through the window's own machinery: two real daemons
// (bob writes to alice's agent), the agent's token from the owner flow, the bash wrapper, a real pseudo-terminal, the
// session-only hook settings and the window's hook channel.
//
// One run, recorded with `claude --version` (printed, and part of every failure message):
// 1. Claude Code starts in a throwaway folder (the folder trust question answered as a person would) and its
//    SessionStart hook arrives;
// 2. a quick reply ("Yes, go ahead.", an AllowedLine typed by the window) is one turn: the hooks report
//    SessionStart, UserPromptSubmit, Stop in that order; after it the window's state machine says idle, and the screen
//    fallback (`claudeCodeReady`) recognises the idle prompt as well. When it does not, the screen rows are printed:
//    that is what a layout change looks like;
// 3. a second quick reply starts a turn, and a message for the agent that arrives while the turn runs is continued by
//    the turn's Stop hook, once, with nothing typed.
//
// It uses this account's HOME, as the window does, so Claude Code must be signed in; it costs a few Haiku turns. It
// runs only with ANTENNA_REAL_CLAUDE=1 and is skipped otherwise. With ANTENNA_REAL_CLAUDE=1 a missing prerequisite is
// a failure, not a skip: a daily job must not read a skip as a pass. The throwaway folder carries project settings for
// Claude Code: Haiku (the cheapest model), Antenna's MCP tools allowed, and the tools that would stop a turn at a
// permission dialog (shell, edits, web) denied, reads outside the test's folder refused, so that every turn ends by
// itself.
// Run: tools/claude-canary.sh, or ANTENNA_REAL_CLAUDE=1 ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test
// --tags real-cli test/protocol/live_code_real_claude_test.dart
@Tags(['live', 'real-cli'])
@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/program_locator.dart';
import 'package:antenna_desktop/host/pty.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/claude_state.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/code/terminal_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart' show TerminalKey;

import '../support/events.dart';
import '../support/pty_native.dart';
import '../support/xd_harness.dart';

// ignore_for_file: avoid_print

/// The switch that turns the canary on.
const enableVar = 'ANTENNA_REAL_CLAUDE';

/// Claude Code's settings for the throwaway project: the cheapest model; Antenna's tools without a question; the
/// tools that could open a permission dialog denied (a denied tool returns an error to the model, the turn goes on).
/// The test's [root] (the project's parent, which the model sometimes searches) is a working directory, and any read
/// further out is refused: 2.1.306 asks "Read outside the working directories" otherwise, and the canary measures
/// the wake, not that dialog (the window itself treats the dialog as one: code_wake_test, claude_state_test).
Map<String, Object> projectSettings(List<String> root) => {
      'model': 'haiku',
      'permissions': {
        'allow': ['mcp__antenna'],
        'deny': ['Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'WebSearch'],
        'additionalDirectories': root,
        'blockReadsOutsideWorkingDirectories': true,
      },
    };

/// A step of the canary went wrong; the message says how, in one line.
final class Broke implements Exception {
  const Broke(this.message);
  final String message;

  @override
  String toString() => message;
}

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 20), required String what}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw Broke('no $what within ${timeout.inSeconds} s');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// `claude --version` as one word (`2.1.289`), or `unknown`.
String claudeVersion(String claude) {
  try {
    final r = Process.runSync(claude, ['--version']);
    return RegExp(r'\d+\.\d+\.\d+[0-9A-Za-z.+-]*').firstMatch('${r.stdout}')?.group(0) ?? 'unknown';
  } on ProcessException {
    return 'unknown';
  }
}

/// Characters a person cannot tell from a space (or does not see at all), shown as `<U+XXXX>` in [describeScreen].
final _invisible =
    RegExp(r'[\u0000-\u001f\u007f-\u009f\u00a0\u00ad\u2000-\u200f\u2028-\u202f\u205f-\u206f\u3000\ufeff]');

/// The screen as the idle checks read it, for a failure message: every row with its number (invisible characters
/// spelled out), where text is drawn faint, and the cursor.
String describeScreen(TerminalScreen s) {
  final b = StringBuffer('cursor at row ${s.cursorRow}, column ${s.cursorColumn}, '
      '${s.cursorVisible ? 'shown' : 'hidden'}\n');
  for (var i = 0; i < s.rows.length; i++) {
    final row = s.rows[i];
    final shown = row.replaceAll(RegExp(r' +$'), '').replaceAllMapped(
        _invisible, (c) => '<U+${c[0]!.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(4, '0')}>');
    b.writeln('${'$i'.padLeft(2)}|$shown');
    final dim = [
      for (var c = 0; c < row.length; c++)
        if (row[c] != ' ' && s.isFaint(i, c)) c,
    ];
    if (dim.isNotEmpty) b.writeln('  |  (faint from column ${dim.first} to ${dim.last})');
  }
  return b.toString();
}

/// Claude Code's folder for a project's transcripts: the path with every character other than a letter or a digit
/// replaced by `-`.
String claudeProjectDir(String home, String path) =>
    '$home/.claude/projects/${path.replaceAll(RegExp('[^A-Za-z0-9]'), '-')}';

void main() {
  final enabled = Platform.environment[enableVar] == '1';
  final antennad = findXd();
  final xCli = antennad == null ? null : '${File(antennad).parent.path}/antenna';
  final env = ownerCliEnv();
  final home = env['HOME'] ?? '';
  final claude = ProgramLocator(env: env).locate(AgentCli.claude.binary);

  test('canary: the Code mode wake works with the real Claude Code installed here', () async {
    var version = 'unknown';
    var stage = 'prerequisites';
    AgentRun? run;
    FileCodeHooks? channel;
    List<String> events() {
      final f = File('${channel?.dir}/events');
      return channel != null && f.existsSync() ? f.readAsLinesSync() : const [];
    }

    /// Wait for the hook event [word] after the first [from] events; a permission dialog or the session's end is a
    /// failure at once (the run's turns must end by themselves).
    Future<int> event(String word, {required int from, Duration timeout = const Duration(seconds: 90)}) async {
      var at = -1;
      await until(() {
        final e = events();
        for (var i = from; i < e.length; i++) {
          if (e[i] == 'permission' || e[i] == 'notify-permission') {
            throw Broke('a permission dialog opened (hook events: ${e.join(' ')})');
          }
          if (e[i] == 'end') throw Broke('Claude Code ended its session (hook events: ${e.join(' ')})');
          if (e[i] == word) {
            at = i;
            return true;
          }
        }
        return false;
      }, timeout: timeout, what: 'hook event "$word"');
      return at;
    }

    /// Wait until the terminal has been silent for [quiet] (Claude Code has finished redrawing).
    Future<void> settle(AgentRun r, {Duration quiet = const Duration(seconds: 2)}) async {
      var seen = r.activity;
      var since = DateTime.now();
      await until(() {
        if (r.activity != seen) {
          seen = r.activity;
          since = DateTime.now();
        }
        return DateTime.now().difference(since) >= quiet;
      }, timeout: const Duration(seconds: 30), what: 'quiet terminal');
    }

    final root = await tempRoot();
    final work = Directory('${root.path}/project')..createSync();
    final projectDirs = {claudeProjectDir(home, work.path), claudeProjectDir(home, work.resolveSymbolicLinksSync())};
    XdNode? alice, bob;
    AppModel? m;
    try {
      if (antennad == null) throw Broke(noXdReason);
      if (claude == null) throw Broke('Claude Code (`claude`) is not on PATH');
      if (!home.startsWith('/')) throw Broke('no HOME');
      version = claudeVersion(claude);
      print('CANARY version $version ($claude)');
      final noPty = await loadPtyLibrary();
      if (noPty != null) throw Broke(noPty);
      Directory('${work.path}/.claude').createSync();
      File('${work.path}/.claude/settings.json').writeAsStringSync(
          jsonEncode(projectSettings({root.path, root.resolveSymbolicLinksSync()}.toList())));

      stage = 'two daemons and a link';
      alice = XdNode('alice', root, antennad);
      bob = XdNode('bob', root, antennad);
      await Future.wait([alice.start(), bob.start()]);
      final a = XControlClient(alice.socket);
      final b = XControlClient(bob.socket);
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
      // Alice's agent announces itself to bob, so that bob can write to it by name.
      final agent = await a.agentAdd('canary', localLevel: 0, password: alice.password, links: ['Bob']);
      final hi = await Process.run(xCli!, ['--json', 'send', 'Bob', 'canary here', '--wait', '3s'],
          environment: {...env, 'ANTENNA_AGENT_TOKEN': agent.token, 'ANTENNA_SOCKET': alice.socket},
          includeParentEnvironment: false);
      if (hi.exitCode != 0) throw Broke('the agent could not write to bob: ${hi.stdout}${hi.stderr}');
      final announced = Stopwatch()..start();
      while (!(await b.contacts()).single.agents.any((x) => x.name == 'canary')) {
        if (announced.elapsed > const Duration(seconds: 20)) throw const Broke('bob does not see the agent');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      stage = 'Start agent';
      final model = m = AppModel(
        connector: XControlClient.new,
        socketPath: alice.socket,
        binaries: CoreBinaries(daemon: antennad, cli: xCli),
        agentHost: AgentHost(
          startPty: SystemPty.start,
          env: env,
          newHooks: () => channel = FileCodeHooks.create('${root.path}/code'),
        ),
      );
      await model.connect();
      final loginErr = await model.login(alice.password);
      if (loginErr != null) throw Broke('login: $loginErr');
      await until(() => model.subscribed, what: 'subscription');
      final startErr = await model.startAgent(AgentRunSpec(agent: 'canary', cli: AgentCli.claude, workDir: work.path),
          auth: PasswordAuth(alice.password));
      if (startErr != null) throw Broke('startAgent: $startErr');
      final r = run = model.runOf('canary')!;
      if (channel == null) throw Broke('the window made no hook channel');
      String screen() => terminalText(r.terminal.buffer);

      stage = 'the folder trust question';
      bool firstRun() => screen().contains('Select login method') || screen().contains('Choose the text style');
      bool trust() => screen().contains('trust this folder');
      await until(() => trust() || firstRun() || events().isNotEmpty,
          timeout: const Duration(seconds: 40), what: 'folder trust question or SessionStart');
      if (firstRun()) throw Broke('Claude Code is not signed in for $home (it shows its first-run screens)');
      if (trust()) {
        // 2.1.233 preselected "Yes"; 2.1.289 preselects "No, exit" and lists "Yes, I trust this folder" second.
        if (screen().contains('❯ No, exit')) {
          await Future<void>.delayed(const Duration(seconds: 1));
          r.terminal.keyInput(TerminalKey.arrowDown);
          await until(() => screen().contains('❯ Yes, I trust this folder'), what: '"Yes" selected');
        }
        r.terminal.textInput('\r');
      }

      stage = 'SessionStart';
      await event('start', from: 0, timeout: const Duration(seconds: 40));
      await until(() => r.claude.state == ClaudeState.idle, what: 'idle after SessionStart');
      await settle(r);

      stage = 'turn 1 (quick reply "Yes, go ahead.")';
      final from1 = events().length;
      model.quickReply(r, QuickReply.goAhead);
      await event('prompt', from: from1, timeout: const Duration(seconds: 30));
      final stop1 = await event('stop', from: from1);
      final order = [
        for (final e in events().take(stop1 + 1))
          if (const {'start', 'prompt', 'stop', 'continued'}.contains(e)) e,
      ];
      print('CANARY turn 1 hook events: ${events().join(' ')}');
      if (order.join(' ') != 'start prompt stop') {
        throw Broke('hook events out of order: expected start prompt stop, got ${order.join(' ')} '
            '(all: ${events().join(' ')})');
      }

      stage = 'idle after Stop (hooks)';
      await until(() => r.claude.state == ClaudeState.idle,
          timeout: const Duration(seconds: 5), what: 'the state machine at idle');
      await settle(r);

      stage = 'idle after Stop (screen fallback)';
      // The fallback must recognise the idle prompt on its own: it decides whenever the hooks cannot.
      final ready = Stopwatch()..start();
      while (!claudeCodeReady(r.screen())) {
        if (ready.elapsed > const Duration(seconds: 10)) {
          throw Broke('claudeCodeReady does not recognise the idle prompt after Stop '
              '(layout known: ${claudeLayoutKnown(r.screen())}, screen guard: ${screenGuard(r.screen())})');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (lineRoute(r.claude, r.screen()) != LineRoute.type) {
        throw Broke('the window would not type at the idle prompt (route ${lineRoute(r.claude, r.screen())})');
      }
      print('CANARY idle screen:\n${describeScreen(r.screen())}');

      stage = 'turn 2 (quick reply "Check the chat")';
      final from2 = events().length;
      model.quickReply(r, QuickReply.checkChat);
      await event('prompt', from: from2, timeout: const Duration(seconds: 30));
      final turn = Stopwatch()..start();

      stage = 'a message for the agent during turn 2';
      await b.send('alice', 'Canary check from Bob: nothing to do, no reply needed.',
          address: const MessageAddress.agent('canary'));
      final sentMs = turn.elapsedMilliseconds;
      int? offeredMs;
      await until(() {
        if (File('${channel!.dir}/continue').existsSync()) offeredMs ??= turn.elapsedMilliseconds;
        final e = events().sublist(from2);
        if (e.contains('continued')) return true;
        if (e.contains('stop')) {
          throw Broke('turn 2 ended without the Stop hook continuing it (message sent $sentMs ms after the '
              'prompt, line left for the hook: ${offeredMs == null ? 'never' : '$offeredMs ms'}; hook events: '
              '${e.join(' ')})');
        }
        return false;
      }, timeout: const Duration(seconds: 90), what: 'the Stop hook continuing the turn');
      final continuedMs = turn.elapsedMilliseconds;

      stage = 'the continued turn';
      final cont = events().indexOf('continued', from2);
      await event('stop', from: cont + 1);
      await until(() => r.claude.state == ClaudeState.idle,
          timeout: const Duration(seconds: 5), what: 'the state machine at idle');

      stage = 'nothing typed after the continuation';
      // The wake's quiet check and the cooldown would type a line that was still waiting within 5 s of quiet.
      await Future<void>.delayed(const Duration(seconds: 8));
      final after = events().sublist(from2);
      print('CANARY turn 2 hook events: ${after.join(' ')}');
      if (after.where((e) => e == 'continued').length != 1) {
        throw Broke('the Stop hook continued ${after.where((e) => e == 'continued').length} times, not once');
      }
      final lines = [for (final e in model.codeLineLog) if (e.kind != CodeLineKind.quick) e];
      if (lines.length != 1 || !lines.single.continued || lines.single.contact != 'Bob') {
        throw Broke('the window gave other lines than one continuation: '
            '${[for (final e in lines) '${e.kind.name}${e.continued ? ' (continued)' : ' (typed)'}'].join(', ')}');
      }
      print('CANARY PASS hooks start>prompt>stop, screen fallback ok, Stop hook continued once '
          '(message $sentMs ms into the turn, continued at $continuedMs ms)');
    } on Object catch (e) {
      final where = 'Claude Code $version, at "$stage"';
      final head = '$e'.split('\n').first;
      print('CANARY FAIL $stage: $head');
      final last = run;
      final shown = last == null ? '(no terminal)' : describeScreen(last.screen());
      fail('$where: $e\nhook events: ${events().join(' ')}\nscreen rows:\n$shown');
    } finally {
      await m?.stopAllRuns();
      m?.dispose();
      await Future.wait([?alice?.stop(), ?bob?.stop()]);
      // Claude Code keeps a transcript per project folder: the throwaway folder's goes with it.
      for (final d in projectDirs) {
        final dir = Directory(d);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
      await root.delete(recursive: true);
    }
  },
      skip: enabled
          ? false
          : 'the Claude Code canary runs only with $enableVar=1 (tools/claude-canary.sh): it needs a signed-in Claude '
              'Code and costs a few Haiku turns',
      timeout: const Timeout(Duration(minutes: 6)));
}
