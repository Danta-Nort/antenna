// SPDX-License-Identifier: AGPL-3.0-only
// Code mode agents restored after an automatic update (D-103, D-UI-29), on
// the fake daemon, a fake pseudo-terminal and a fake hook channel: the window that comes back after the installer
// starts again the same CLI in its last session (`claude --resume <id>`), with the daemon's token file in its
// environment and no token anywhere in its arguments, and types the built-in update line once, at the idle prompt
// only. Nothing is restored while the daemon is locked, without `status.updated`, after a normal quit, for an agent
// started after the update came up, or twice. Before anyone signs in, `agent_watch` wakes the restored agent; once the
// owner signs in, the owner subscription takes over. The record behind it lives in window.json.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/code_restore.dart';
import 'package:antenna_desktop/state/code_wake.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:antenna_desktop/ui/agents/agents_page.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/claude_screens.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);
const _pw = 'correct horse battery';
const _me = 'claude-backend';
const _dir = '/home/owner/shop';
const _id = '5f0c2a9e-7d41-4b8e-9a63-2c1d0e8f4b17';
const _tokenFile = '/home/owner/.local/share/antenna/agents/claude-backend.token';
const _line = 'Antenna was updated to 0.1.3: read your inbox and continue.';

/// A screen in a layout no Claude Code version drew (the hooks decide; the screen guard only needs the cursor).
const _anyLayout = ClaudeScreen(['claude> ', ''], cursor: (0, 8));

/// The update came up 2 minutes ago; the agent had been started an hour before it.
final _up = UpdatedInfo(from: '0.1.2', to: '0.1.3', atMs: ms(ago(minutes: 2)), unlocked: true);

Map<String, Object?> _record({
  String cli = 'claude',
  bool running = true,
  Object? session = _id,
  String? tokenFile = _tokenFile,
  bool? restore,
  int? startedMs,
  String dir = _dir,
}) =>
    {
      'cli': cli,
      'dir': dir,
      'running': ?(running ? true : null),
      'session': ?session,
      'token_file': ?tokenFile,
      'restore': ?restore,
      'started_ms': startedMs ?? ms(ago(hours: 1)),
    };

final class _World {
  _World(this.m, this.d, this.c, this.store);
  final AppModel m;
  final FakeDaemon d;
  final FakeAgentComputer c;
  final Appearance store;

  Map<String, Object?> get record => store.agentRunRecord(_me) ?? const {};
}

/// The window starting after the installer opened it again: the daemon unlocked by the update ([updated]), nobody
/// signed in ([session] `false`), the agent's record as the window left it.
Future<_World> _restart({
  Map<String, Object?>? record,
  UpdatedInfo? updated,
  bool noUpdate = false,
  DaemonState state = DaemonState.unlocked,
  bool session = false,
  Set<String> files = const {_tokenFile},
}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), state: state)
    ..agentList = [const AgentInfo(name: _me, createdMs: 0, localLevel: 5, everyone: false)]
    ..updated = noUpdate ? null : (updated ?? _up);
  if (!session) d.sessionToken = null;
  final store = Appearance(agentRuns: {_me: record ?? _record()});
  final c = FakeAgentComputer(hooks: true, installed: {'/usr/local/bin/claude', '/opt/homebrew/bin/codex', ...files});
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: c.host,
    defaultSocket: d.socketPath,
    agentRuns: store,
  );
  await m.connect();
  return _World(m, d, c, store);
}

Future<void> _end(WidgetTester t, AppModel m) async {
  m.closeAgentWatches();
  m.disposeCodeWake();
  await t.pump(AgentRun.enterDelay);
}

void main() {
  testWidgets('after an automatic update the agent comes back in its session: claude --resume <id>, the token file in '
      'the environment, no token anywhere, no password', (t) async {
    final w = await _restart();
    final m = w.m;
    expect(m.phase, Phase.loginRequired, reason: 'nobody has signed in to the new window');
    final launch = w.c.launches.single;
    expect(launch.command.first, '/usr/local/bin/claude');
    expect(launch.command.sublist(launch.command.length - 2), ['--resume', _id]);
    expect(launch.command, isNot(contains('--continue')));
    expect(launch.environment[tokenFileVar], _tokenFile);
    expect(launch.environment.containsKey('ANTENNA_AGENT_TOKEN'), isFalse);
    expect(launch.arguments.join(' '), isNot(contains('xat_')));
    expect(launch.arguments.join(' '), isNot(contains(_tokenFile)));
    expect(launch.workingDirectory, _dir);
    expect(w.d.calls, isNot(contains('agent_token')), reason: 'the token file is there: no owner flow, no password');
    expect(w.d.passwords, isEmpty);
    final run = m.runOf(_me)!;
    expect((run.alive, run.restoredTo, run.tokenFile, run.sessionId), (true, '0.1.3', _tokenFile, _id));
    expect(w.record['restored_ms'], _up.atMs);
    expect(w.record['running'], isTrue);
    expect(m.restoredAgents, [_me]);
    await _end(t, m);
  });

  testWidgets('the update line: once, when Claude Code is idle at its prompt, never into a running turn or a dialog',
      (t) async {
    final w = await _restart();
    final pty = w.c.last..emit(drawScreen(_anyLayout));
    final hooks = w.c.hookChannels.single;
    await t.pump();
    // A permission dialog right after the resume: nothing typed.
    hooks.emit(ClaudeHookEvent.permission);
    await t.pump(const Duration(seconds: 10));
    expect(pty.written, isEmpty);
    // The owner's answer runs a turn: the line is left for its Stop hook, still nothing typed.
    hooks.emit(ClaudeHookEvent.tool);
    await t.pump(const Duration(seconds: 10));
    expect(pty.written, isEmpty);
    expect(json.decode(hooks.waiting!)['reason'], _line);
    // The Stop hook could not continue (stop_hook_active): the window takes it back and types it at the prompt.
    hooks.stop(active: true);
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_line, '\r']);
    final last = w.m.lastCodeLine(_me)!;
    expect((last.kind, last.version, last.continued), (CodeLineKind.updated, '0.1.3', false));
    // Once: more idle stops, quiet time and the rate limit later, nothing else.
    hooks.emit(ClaudeHookEvent.stop);
    await t.pump(const Duration(minutes: 2));
    hooks.emit(ClaudeHookEvent.stop);
    await t.pump(const Duration(minutes: 2));
    expect(pty.written, [_line, '\r']);
    expect(w.m.updateLinePending(w.m.runOf(_me)!), isFalse);
    await _end(t, w.m);
  });

  testWidgets('a running turn after the resume: the Stop hook continues it with the update line; nothing is typed',
      (t) async {
    final w = await _restart();
    final pty = w.c.last..emit(drawScreen(_anyLayout));
    final hooks = w.c.hookChannels.single..emit(ClaudeHookEvent.prompt);
    await t.pump();
    expect(json.decode(hooks.waiting!)['reason'], _line);
    expect(hooks.stop(), isNotNull);
    await t.pump(const Duration(minutes: 2));
    expect(pty.written, isEmpty);
    expect(w.m.lastCodeLine(_me)!.continued, isTrue);
    await _end(t, w.m);
  });

  testWidgets('nothing is restored while the daemon is locked; once the owner unlocks, the agent comes back', (t) async {
    final w = await _restart(state: DaemonState.locked);
    expect(w.m.phase, Phase.locked);
    expect(w.c.launches, isEmpty);
    expect(await w.m.unlock(_pw), isNull);
    expect(w.c.launches.single.command, containsAllInOrder(['--resume', _id]));
    await _end(t, w.m);
  });

  testWidgets('nothing is restored without status.updated, after a normal quit, for an agent started after the update, '
      'twice for one update, or without what the restore needs', (t) async {
    final cases = <String, Future<_World> Function()>{
      'no status.updated (a restart that was not an update)': () => _restart(noUpdate: true),
      'not running when the window went away (a normal quit cleared it)': () => _restart(record: _record(running: false)),
      'started after the update came up': () => _restart(record: _record(startedMs: ms(ago(minutes: 1)))),
      'already restored for this update': () => _restart(record: {..._record(), 'restored_ms': _up.atMs}),
      'the switch is off': () => _restart(record: _record(restore: false)),
      'no session ID': () => _restart(record: _record(session: null)),
      'a session ID that is not a UUID': () => _restart(record: _record(session: '../../x --dangerously-skip-permissions')),
      'no token file': () => _restart(record: _record(tokenFile: null)),
      'the token file is gone': () => _restart(files: const {}),
      'a token file that is not the agent\'s': () => _restart(record: _record(tokenFile: '/home/owner/.ssh/id_ed25519')),
      'the folder is gone': () => _restart(record: _record(dir: '/missing/shop')),
      'an own command': () => _restart(record: {..._record(cli: 'custom'), 'cmd': 'aider'}),
    };
    for (final MapEntry(key: why, value: start) in cases.entries) {
      final w = await start();
      expect(w.c.launches, isEmpty, reason: why);
      expect(w.m.restoredAgents, isEmpty, reason: why);
      await _end(t, w.m);
    }
    // Twice: a second connect of the same window (or a window that crashed after the restore) starts nothing more.
    final w = await _restart();
    expect(w.c.launches.length, 1);
    await w.m.connect();
    w.m.restoreAfterUpdate();
    expect(w.c.launches.length, 1);
    await _end(t, w.m);
  });

  testWidgets('the record: running from the start, the session ID the hooks recorded, cleared by Stop and by the '
      'window\'s quit; a window killed by the installer leaves it set', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
      ..agentList = [const AgentInfo(name: _me, createdMs: 0, localLevel: 5, everyone: false)];
    final store = Appearance();
    final c = FakeAgentComputer(hooks: true);
    final m = AppModel(
      connector: (_) => d,
      socketPath: d.socketPath,
      live: false,
      clock: () => fixedNow,
      binaries: _bins,
      agentHost: c.host,
      defaultSocket: d.socketPath,
      agentRuns: store,
    );
    await m.connect();
    const spec = AgentRunSpec(agent: _me, cli: AgentCli.claude, workDir: _dir);
    expect(m.hasAgentToken(_me), isFalse);
    expect(await m.startAgent(spec, auth: PasswordAuth(_pw)), isNull);
    // "Restore after an update" is on by default: the agent gets a token file, not a token in the window's memory.
    expect(d.calls, contains('agent_token'));
    final launch = c.last.launch;
    expect(launch.environment[tokenFileVar], d.tokenFileOf(_me));
    expect(launch.environment.containsKey('ANTENNA_AGENT_TOKEN'), isFalse);
    expect(launch.arguments.join(' '), isNot(contains('xat_')));
    final r = store.agentRunRecord(_me)!;
    expect((r['cli'], r['dir'], r['running'], r['token_file'], r['session']), ('claude', _dir, true, d.tokenFileOf(_me), null));
    expect(r['started_ms'], ms(fixedNow));
    expect(json.encode(r), isNot(contains('xat_')), reason: 'a path, never the token');
    // Claude Code's hooks report its session: kept; anything else is not.
    c.hookChannels.single.session('not-a-session');
    c.hookChannels.single.session(_id);
    expect(store.agentRunRecord(_me)!['session'], _id);
    // A restart needs no password: the token file is the window's for this session.
    expect(m.hasAgentToken(_me), isTrue);

    await m.stopRun(m.runOf(_me)!);
    expect(store.agentRunRecord(_me)!.containsKey('running'), isFalse, reason: 'the owner stopped it');
    expect(await m.restartRun(m.runOf(_me)!), isNull);
    expect(store.agentRunRecord(_me)!['running'], isTrue);
    expect(c.launches.last.environment[tokenFileVar], d.tokenFileOf(_me));
    expect(c.launches.last.command, isNot(contains('--resume')), reason: 'a restart is a new conversation');
    await m.stopAllRuns();
    expect(store.agentRunRecord(_me)!.containsKey('running'), isFalse, reason: 'the window\'s quit question stops all');

    expect(await m.startAgent(spec), isNull);
    expect(store.agentRunRecord(_me)!['running'], isTrue);
    // The installer's SIGTERM: the window process is gone before any of its code runs; only the model is torn down.
    m.disposeRuns();
    expect(store.agentRunRecord(_me)!['running'], isTrue, reason: 'left set for the restore');
    m.disposeCodeWake();
  });

  testWidgets('"Restore after an update" off: the agent keeps a token in memory; the switch is in the tab menu and in '
      'Agents, kept in window.json', (t) async {
    final dir = Directory.systemTemp.createTempSync('antenna-restore-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = AppearanceStore('${dir.path}/window.json');
    final store = settledLook(file)..ui = InterfaceMode.code;
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
      ..agentList = [const AgentInfo(name: _me, createdMs: 0, localLevel: 5, everyone: false)];
    final c = FakeAgentComputer(hooks: true);
    final m = AppModel(
      connector: (_) => d,
      socketPath: d.socketPath,
      live: false,
      clock: () => fixedNow,
      binaries: _bins,
      agentHost: c.host,
      defaultSocket: d.socketPath,
      agentRuns: store,
    );
    await m.connect();
    expect(await m.startAgent(const AgentRunSpec(agent: _me, cli: AgentCli.claude, workDir: _dir), auth: PasswordAuth(_pw)), isNull);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: m, appearance: store));
    await t.pump(const Duration(milliseconds: 400));

    await t.tap(find.byKey(const Key('code-menu')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(t.widget<CheckedPopupMenuItem<Object?>>(find.byKey(const Key('code-restore-toggle'))).checked, isTrue,
        reason: 'on by default');
    expect(find.byKey(const Key('experimental-code-restore')), findsOneWidget);
    await t.tap(find.byKey(const Key('code-restore-toggle')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(m.codeRestoreOn(_me), isFalse);
    expect((json.decode(File(file.path).readAsStringSync())['agent_runs'] as Map)[_me]['restore'], isFalse);

    // The next start: a token in memory, as before D-103.
    await m.stopRun(m.runOf(_me)!);
    expect(await m.startAgent(const AgentRunSpec(agent: _me, cli: AgentCli.claude, workDir: _dir), auth: PasswordAuth(_pw)),
        isNull);
    final launch = c.launches.last;
    expect(launch.environment['ANTENNA_AGENT_TOKEN'], startsWith('xat_'));
    expect(launch.environment.containsKey(tokenFileVar), isFalse);

    // Agents (Code mode): the same switch.
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 300));
    final sw = find.byKey(const Key('agent-code-restore-$_me'));
    await t.scrollUntilVisible(sw, 300,
        scrollable: find.descendant(of: find.byType(AgentsPage), matching: find.byType(Scrollable)).first);
    await t.pump();
    expect(t.widget<Switch>(sw).value, isFalse);
    await t.tap(sw);
    await t.pump(const Duration(milliseconds: 300));
    expect(m.codeRestoreOn(_me), isTrue);
    await _end(t, m);
  });

  testWidgets('wake without a session: agent_watch for the restored agent until the owner signs in', (t) async {
    final w = await _restart();
    final m = w.m;
    final pty = w.c.last..emit(drawScreen(_anyLayout));
    final hooks = w.c.hookChannels.single..emit(ClaudeHookEvent.start);
    final watch = w.d.watches.single;
    expect((watch.request as AgentWatchRequest).agent, _me);
    watch.emit(const Subscribed(proto: 'x-control/7', role: 'agent'));
    await t.pump();
    expect(m.watchingAgent(_me), isTrue);
    // The update line first (idle, 5 s after the resumed screen was drawn), then the rate limit.
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_line, '\r']);
    await t.pump(const Duration(seconds: 31));
    // A message the agent may read, as a fact (the daemon applied its visibility rule): the wake line.
    watch.emit(MessageFactEvent(contact: emilyName, id: hex(1), trust: 4, chars: 120));
    await t.pump();
    hooks.emit(ClaudeHookEvent.stop);
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written.skip(2), ['New Antenna messages from $emilyName: read your inbox and continue.', '\r']);

    // The owner signs in: the owner subscription takes over, the watch is closed and not opened again.
    expect(await m.login(_pw), isNull);
    expect(m.phase, Phase.unlocked);
    expect(watch.cancelled, isTrue);
    expect(w.d.watches.length, 1);
    await _end(t, m);
  });

  testWidgets('wake without a session: a request to answer from agent_watch gives the approver line, once per request',
      (t) async {
    final w = await _restart();
    final m = w.m;
    final pty = w.c.last..emit(drawScreen(_anyLayout));
    final hooks = w.c.hookChannels.single..emit(ClaudeHookEvent.start);
    final watch = w.d.watches.single..emit(const Subscribed(proto: 'x-control/7', role: 'agent'));
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(pty.written, [_line, '\r']);
    await t.pump(const Duration(seconds: 31));
    // Facts only (CONTROL §31): the request's ID, its computer, the action and who asked
    const fact = ApprovalToAnswerEvent(id: 'k9', device: 'Mac mini', action: 'send_message', requester: 'session-2');
    watch.emit(fact);
    hooks.emit(ClaudeHookEvent.stop);
    await t.pump(const Duration(seconds: 6));
    await t.pump(AgentRun.enterDelay);
    const line = 'An approval request waits for your answer: read approvals_to_answer and answer it.';
    expect(pty.written.skip(2), [line, '\r']);
    await t.pump(const Duration(seconds: 31));
    watch.emit(fact);
    hooks.emit(ClaudeHookEvent.stop);
    await t.pump(const Duration(seconds: 6));
    expect(pty.written.skip(2), [line, '\r'], reason: 'the same request wakes it once');
    await _end(t, m);
  });

  testWidgets('no watch while the window has a session, or for an agent the window did not restore', (t) async {
    final w = await _restart(session: true);
    expect(w.m.phase, Phase.unlocked);
    expect(w.c.launches.length, 1, reason: 'restored all the same');
    expect(w.d.watches, isEmpty, reason: 'the owner subscription wakes it');
    await _end(t, w.m);
  });

  testWidgets('a daemon without agent_watch: no watch; the sign-in screen says so, and the dock after sign-in', (t) async {
    final w = await _restart();
    w.d.agentWatchSupported = false;
    // The refusal arrives for the watch opened at the restore.
    w.m.closeAgentWatches();
    w.m.syncAgentWatches();
    await t.pump();
    expect(w.m.runOf(_me)!.watchUnavailable, isTrue);
    t.view.physicalSize = const Size(1440, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(XApp(model: w.m));
    await t.pump(const Duration(milliseconds: 400));
    final note = find.byKey(const Key('gate-restored'));
    expect(note, findsOneWidget);
    expect(find.descendant(of: note, matching: find.textContaining(en.gateRestored('0.1.3', _me))),
        findsOneWidget);
    expect(find.descendant(of: note, matching: find.textContaining(en.gateRestoredNoWake)), findsOneWidget);

    expect(await w.m.login(_pw), isNull);
    await t.pumpWidget(XApp(model: w.m, appearance: Appearance(ui: InterfaceMode.code)));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('${en.codeRestoredNote('0.1.3')} · ${en.codeWatchUnavailable}'), findsOneWidget);
    await _end(t, w.m);
  });

  testWidgets('Codex comes back with codex resume <id>, its notify program and the token file; no line is typed',
      (t) async {
    final w = await _restart(record: _record(cli: 'codex'));
    final launch = w.c.launches.single;
    expect(launch.command.first, '/opt/homebrew/bin/codex');
    expect(launch.command.sublist(launch.command.length - 2), ['resume', _id]);
    expect(launch.command, contains('notify=["/bin/sh","/fake/hooks/notify.sh"]'));
    expect(launch.command, contains('mcp_servers.antenna.env_vars=["$tokenFileVar", "ANTENNA_SOCKET"]'));
    expect(launch.environment[tokenFileVar], _tokenFile);
    expect(launch.command, contains('hooks.Stop=[{hooks=[{type="command",command="/bin/sh \\"\$ANTENNA_CODE_HOOKS/hook.sh\\" stop"}]}]'));
    await t.pump(const Duration(minutes: 1));
    expect(w.c.last.written, isEmpty, reason: 'nothing until Codex shows its empty composer');
    expect(w.d.watches, hasLength(1), reason: 'a restored Codex is woken too (PG-21)');
    // Its empty composer: the update line, as for Claude Code
    w.c.last.emit(drawScreen(ClaudeScreen([
      '• Ready.',
      '',
      '› ${faint('Ask Codex to do anything')}',
      '',
      '  ? for shortcuts',
    ], cursor: (2, 2))));
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    expect(w.c.last.written.first, startsWith('Antenna was updated to'));
    await _end(t, w.m);
  });

  testWidgets('the version in the line is sanitized: SemVer characters only, at most 40', (t) async {
    final w = await _restart(
        updated: UpdatedInfo(
            from: '0.1.2', to: '0.1.3\x1b[2J\r\n; rm -rf ~ ${'9' * 60}', atMs: _up.atMs, unlocked: true));
    final pty = w.c.last..emit(drawScreen(_anyLayout));
    w.c.hookChannels.single.emit(ClaudeHookEvent.start);
    await t.pump(const Duration(seconds: 11));
    await t.pump(AgentRun.enterDelay);
    final typed = pty.written.first;
    expect(typed, startsWith('Antenna was updated to 0.1.32Jrm-rf'));
    expect(typed, isNot(contains('\x1b')));
    expect(typed, isNot(contains(';')));
    expect(sanitizeVersion('0.1.3\x1b[2J; rm -rf ~ ${'9' * 60}').length, maxLineVersion);
    expect(AllowedLine.updated('\x1b;').text, 'Antenna was updated: read your inbox and continue.');
    await _end(t, w.m);
  });

  test('the refusal reasons, one by one', () {
    bool folder(String d) => !d.startsWith('/missing');
    bool isFile(String p) => p == _tokenFile;
    RestoreRefusal? why(Map<String, Object?> j, {bool alive = false}) =>
        restoreRefusal(RestoreRecord.of(_me, j), _up, alive: alive, folderExists: folder, isFile: isFile);
    expect(why(_record()), isNull);
    expect(why(_record(running: false)), RestoreRefusal.notRunning);
    expect(why(_record(restore: false)), RestoreRefusal.switchedOff);
    expect(why({..._record(cli: 'custom'), 'cmd': 'aider'}), RestoreRefusal.ownCommand);
    expect(why(_record(session: 'abc')), RestoreRefusal.noSession);
    expect(why(_record(startedMs: _up.atMs)), RestoreRefusal.startedAfterUpdate);
    expect(why({..._record(), 'restored_ms': _up.atMs}), RestoreRefusal.alreadyRestored);
    expect(why(_record(tokenFile: '/home/owner/.local/share/antenna/agents/other.token')), RestoreRefusal.noTokenFile);
    expect(why(_record(tokenFile: '/home/owner/.local/share/antenna/agents/../agents/claude-backend.token')),
        RestoreRefusal.noTokenFile);
    expect(why(_record(dir: '/missing/x')), RestoreRefusal.noFolder);
    expect(why(_record(), alive: true), RestoreRefusal.alreadyRunning);
  });
}
