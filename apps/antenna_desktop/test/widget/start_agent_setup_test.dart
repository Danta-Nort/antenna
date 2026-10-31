// SPDX-License-Identifier: AGPL-3.0-only
// Start an agent → "Set up this folder" (D-124) on the fake daemon and the fake computer (its folders in memory, a
// git that records): compact with one line of what Start will do; the defaults (instructions while AGENTS.md is
// missing, Antenna's tools for Claude Code, no git); the exact plan shown before anything is written; Start applies
// the plan, then starts the agent; a refusal (settings that are not strict JSON) or a failing git starts nothing; a
// folder that has everything says so; Codex gets no CLAUDE.md and no rules, an own command no section.

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_setup.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/code/start_agent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);

const _own = '/home/owner/Antenna/agents/jarvis';

Future<(AppModel, FakeDaemon, FakeAgentComputer)> _setup() async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..agentList = [const AgentInfo(name: 'jarvis', createdMs: 0, localLevel: 5)];
  final c = FakeAgentComputer();
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: c.host,
    defaultSocket: d.socketPath,
  );
  await m.connect();
  addTearDown(() {
    for (final r in m.runs) {
      r.kill();
    }
  });
  return (m, d, c);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _open(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('code-start-empty')));
  await _settle(t);
  // The agent list arrives after the first frame, then the folder is read: one more frame shows what it has.
  await _settle(t);
  expect(find.byType(StartAgentDialog), findsOneWidget);
}

Finder _key(String k) => find.byKey(Key(k));

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}

bool _ticked(WidgetTester t, String key) => t.widget<Checkbox>(_key(key)).value!;

String _summary(WidgetTester t) => t.widget<Text>(_key('setup-summary')).data!;

String _willDo(List<String> steps) => en.setupWillDo(steps.join(', '));

/// The plan as "What will be written" shows it.
String _preview(WidgetTester t) =>
    t.widget<SelectableText>(find.descendant(of: _key('setup-preview'), matching: find.byType(SelectableText))).data!;

Future<void> _start(WidgetTester t) async {
  await t.enterText(_key('owner-password'), 'correct horse battery');
  await _tap(t, _key('code-start-go'));
}

void main() {
  testWidgets('tick, read exactly what will be written, Start: the folder is set up, then the agent starts', (t) async {
    final (m, d, pc) = await _setup();
    await _open(t, m);
    // Compact: one line of what Start will do, from the defaults.
    expect(_summary(t), _willDo([en.setupDoWrite('AGENTS.md'), en.setupDoWrite('CLAUDE.md'), en.setupDoRules(1)]));
    expect(_key('setup-instructions'), findsNothing, reason: 'collapsed until opened');

    await _tap(t, _key('setup-toggle'));
    expect(_ticked(t, 'setup-instructions'), isTrue, reason: 'AGENTS.md is missing');
    expect(_ticked(t, 'setup-git'), isFalse);
    expect(_ticked(t, 'setup-rule-antenna-tools'), isTrue);
    expect(_ticked(t, 'setup-rule-antenna-cli'), isFalse);
    expect(_ticked(t, 'setup-rule-git'), isFalse);

    // Git ticked without a name: Start says so and does nothing.
    await _tap(t, _key('setup-git'));
    await _start(t);
    expect(find.text(en.setupErrGitIdentity), findsOneWidget);
    expect(pc.folders.log, isEmpty);
    expect(d.calls, isNot(contains('agent_token')));

    await t.enterText(_key('setup-git-name'), 'Robin Example');
    await t.enterText(_key('setup-git-email'), 'robin@example.com');
    await _tap(t, _key('setup-rule-git'));
    await _tap(t, _key('setup-preview-toggle'));
    final preview = _preview(t);
    expect(preview, startsWith(en.setupStepHead(_own)));
    expect(preview, contains('  ${en.setupStepWrite('$_own/AGENTS.md')}\n'));
    expect(preview, contains('    | This folder is the workspace of the agent `jarvis`, connected to Antenna'));
    expect(preview, contains('  ${en.setupStepWrite('$_own/CLAUDE.md')}\n    | @AGENTS.md\n'));
    expect(preview, contains(en.setupStepRun(_own, 'git init')));
    expect(preview, contains(en.setupStepRun(_own, "git config user.name 'Robin Example'")));
    expect(preview, contains(en.setupStepRun(_own, 'git config user.email robin@example.com')));
    expect(preview, contains(en.setupStepRules('$_own/.claude/settings.json', 'mcp__antenna, Bash(git:*)')));
    expect(preview, contains('    |       "mcp__antenna",'));
    expect(pc.folders.log, isEmpty, reason: 'nothing is written before Start');
    expect(pc.git.runs, isEmpty);

    await _start(t);
    expect(find.byType(StartAgentDialog), findsNothing);
    expect(pc.folders.files['$_own/AGENTS.md'], agentsMdTemplate.replaceAll('{agent}', 'jarvis'));
    expect(pc.folders.files['$_own/CLAUDE.md'], '@AGENTS.md\n');
    expect(pc.folders.files['$_own/.claude/settings.json'],
        '{\n  "permissions": {\n    "allow": [\n      "mcp__antenna",\n      "Bash(git:*)"\n    ]\n  }\n}\n');
    expect([for (final (dir, argv) in pc.git.runs) '$dir: ${argv.join(' ')}'], [
      '$_own: git init',
      '$_own: git config user.name Robin Example',
      '$_own: git config user.email robin@example.com',
    ]);
    // Then the start as before.
    expect(d.calls.where((c) => c == 'agent_token'), hasLength(1));
    expect(pc.last.launch.workingDirectory, _own);
  });

  testWidgets('settings that are not strict JSON: the section says why, Start starts nothing; unticked, it starts',
      (t) async {
    final (m, d, pc) = await _setup();
    const odd = '{ // mine\n  "permissions": {} }';
    pc.folders.files['$_own/.claude/settings.json'] = odd;
    await _open(t, m);
    expect(_summary(t), en.setupErrNotJson('$_own/.claude/settings.json'));

    await _start(t);
    expect(find.byType(StartAgentDialog), findsOneWidget);
    expect(find.text(en.setupErrNotJson('$_own/.claude/settings.json')), findsNWidgets(2),
        reason: 'the line and the error');
    expect(pc.folders.log, isEmpty, reason: 'a refused plan writes nothing, not even AGENTS.md');
    expect(pc.folders.files['$_own/.claude/settings.json'], odd);
    expect(d.calls, isNot(contains('agent_token')));
    expect(pc.ptys, isEmpty);

    await _tap(t, _key('setup-toggle'));
    await _tap(t, _key('setup-rule-antenna-tools'));
    expect(_summary(t), _willDo([en.setupDoWrite('AGENTS.md'), en.setupDoWrite('CLAUDE.md')]));
    await _start(t);
    expect(find.byType(StartAgentDialog), findsNothing);
    expect(pc.folders.files['$_own/.claude/settings.json'], odd);
    expect(pc.folders.files.keys, contains('$_own/AGENTS.md'));
    expect(pc.ptys, hasLength(1));
  });

  testWidgets('a failing git: the error, and the agent is not started', (t) async {
    final (m, d, pc) = await _setup();
    pc.git.exitCode = 128;
    await _open(t, m);
    await _tap(t, _key('setup-toggle'));
    await _tap(t, _key('setup-git'));
    await t.enterText(_key('setup-git-name'), 'Robin Example');
    await t.enterText(_key('setup-git-email'), 'robin@example.com');
    await _start(t);
    expect(find.text(en.setupErrCommandExit('git init', 128)), findsOneWidget);
    expect(find.byType(StartAgentDialog), findsOneWidget);
    expect(d.calls, isNot(contains('agent_token')));
    expect(pc.ptys, isEmpty);
  });

  testWidgets('a folder that has everything says so, and Start changes nothing in it', (t) async {
    final (m, _, pc) = await _setup();
    pc.folders.files
      ..['$_own/AGENTS.md'] = 'mine\n'
      ..['$_own/CLAUDE.md'] = '@AGENTS.md\n'
      ..['$_own/.claude/settings.json'] = '{"permissions": {"allow": ["mcp__antenna"]}}';
    await _open(t, m);
    expect(_summary(t), en.setupInPlace);
    await _tap(t, _key('setup-toggle'));
    expect(_ticked(t, 'setup-instructions'), isFalse, reason: 'AGENTS.md is there');
    // Ticked anyway: the files that are there are kept, and shown as kept.
    await _tap(t, _key('setup-instructions'));
    expect(_summary(t), en.setupInPlace);
    await _tap(t, _key('setup-preview-toggle'));
    final preview = _preview(t);
    expect(preview, contains(en.setupStepKeep('$_own/AGENTS.md')));
    expect(preview, contains(en.setupStepKeep('$_own/CLAUDE.md')));
    expect(preview, isNot(contains('settings.json')), reason: 'the rule is there already');
    await _start(t);
    expect(find.byType(StartAgentDialog), findsNothing);
    expect(pc.folders.log, isEmpty);
    expect(pc.folders.files['$_own/AGENTS.md'], 'mine\n');
  });

  testWidgets('Codex: AGENTS.md only, no Claude Code rules; an own command: no section at all', (t) async {
    final (m, _, pc) = await _setup();
    await _open(t, m);
    await _tap(t, _key('code-cli-codex'));
    expect(_summary(t), en.setupWillDo(en.setupDoWrite('AGENTS.md')));
    await _tap(t, _key('setup-toggle'));
    expect(_key('setup-rule-antenna-tools'), findsNothing);
    expect(find.text(en.setupInstructionsHint('AGENTS.md')), findsOneWidget);
    await _tap(t, _key('code-cli-custom'));
    expect(_key('setup'), findsNothing);
    await _tap(t, _key('code-cli-codex'));
    await _start(t);
    expect(find.byType(StartAgentDialog), findsNothing);
    expect(pc.folders.files.keys, ['$_own/AGENTS.md']);
  });

  testWidgets('a project folder the owner chose: nothing ticked by default, nothing written unless ticked', (t) async {
    final (m, _, pc) = await _setup();
    const project = '/home/owner/projects/volna';
    pc.folders.dirs.add(project);
    await _open(t, m);
    await t.enterText(_key('code-folder'), project);
    await _settle(t);
    // Its repository is the owner's: no instruction file or rule goes there by default
    expect(_summary(t), en.setupNothing);
    await _tap(t, _key('setup-toggle'));
    expect(_ticked(t, 'setup-instructions'), isFalse);
    expect(_ticked(t, 'setup-rule-antenna-tools'), isFalse);
    await _tap(t, _key('setup-rule-antenna-tools'));
    expect(_summary(t), en.setupWillDo(en.setupDoRules(1)));
    await _start(t);
    expect(find.byType(StartAgentDialog), findsNothing);
    expect(pc.folders.files.keys, ['$project/.claude/settings.json']);
    expect(pc.last.launch.workingDirectory, project);
  });

  testWidgets('a new agent: the section waits for its name, then plans for its own folder; a typed folder that does '
      'not exist is refused', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final pc = FakeAgentComputer();
    final m = AppModel(
        connector: (_) => d,
        socketPath: d.socketPath,
        live: false,
        clock: () => fixedNow,
        binaries: _bins,
        agentHost: pc.host,
        defaultSocket: d.socketPath);
    await m.connect();
    addTearDown(() {
      for (final r in m.runs) {
        r.kill();
      }
    });
    await _open(t, m);
    expect(_summary(t), en.setupNeedsName);
    await t.enterText(_key('agent-name'), 'scout');
    await _settle(t);
    expect(_summary(t), _willDo([en.setupDoWrite('AGENTS.md'), en.setupDoWrite('CLAUDE.md'), en.setupDoRules(1)]));
    // A folder typed by hand that does not exist: the setup refuses it (only the agent's own folder is made).
    await t.enterText(_key('code-folder'), '/missing/project');
    await _settle(t);
    expect(_summary(t), en.setupErrNotFolder('/missing/project'));
  });
}
