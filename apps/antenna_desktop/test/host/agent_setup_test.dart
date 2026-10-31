// SPDX-License-Identifier: AGPL-3.0-only
// "Set up this folder" (state/agent_setup.dart) on the real disk, in a temporary folder: the agent's own folder made
// private, the templates written where missing and an existing file kept, `.claude/settings.json` merged after a
// backup with everything else kept, anything but strict JSON refused and left untouched, a new file never written
// over another or through a link, a failing git stopping the setup. git itself is a recording fake here, and the real
// git once at the end (when it is installed).

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/agent_folder.dart';
import 'package:antenna_desktop/state/agent_setup.dart';
import 'package:flutter_test/flutter_test.dart';

int _mode(String path) => FileStat.statSync(path).mode & 0x1FF;

/// Records the commands; `git init` makes `.git` and `git config` remembers, so a second plan sees them.
class _Git implements AgentFolderGit {
  final runs = <(String, List<String>)>[];
  final config = <String, String>{};
  int exitCode = 0;

  @override
  Future<String?> localConfig(String dir, String key) async => config[key];

  @override
  Future<int> run(String dir, List<String> argv) async {
    runs.add((dir, argv));
    if (exitCode != 0) return exitCode;
    switch (argv) {
      case ['git', 'init']:
        Directory('$dir/.git').createSync();
      case ['git', 'config', final key, final value]:
        config[key] = value;
    }
    return 0;
  }
}

void main() {
  const fs = DiskAgentFolder();
  late Directory tmp;
  late _Git git;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('agent-setup-test-');
    git = _Git();
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<AgentSetupPlan> plan(String dir, AgentSetupChoice choice, {bool own = false, bool claudeCode = true}) async =>
      planAgentSetup(await inspectAgentFolder(fs, git, dir, own: own),
          agent: 'dev', claudeCode: claudeCode, choice: choice);

  String read(String path) => File(path).readAsStringSync();

  test('the agent\'s own folder: made 0700, the templates, the identity through git, the rules; once', () async {
    final dir = '${tmp.path}/Antenna/agents/dev';
    const choice = AgentSetupChoice(
        instructions: true, gitName: 'Robin Example', gitEmail: 'robin@example.com', allow: {'antenna-tools', 'git'});
    final p = await plan(dir, choice, own: true);
    expect(p.steps.first, isA<CreateFolderStep>());
    expect([for (final s in p.steps.whereType<RunStep>()) setupCommandLine(s.argv)],
        ['git init', 'git config user.name \'Robin Example\'', 'git config user.email robin@example.com']);
    await applyAgentSetup(p, fs, git);

    expect(_mode(dir), 0x1C0, reason: 'only the owner can open the agent\'s own folder');
    expect(read('$dir/AGENTS.md'), agentsMdTemplate.replaceAll('{agent}', 'dev'));
    expect(read('$dir/AGENTS.md'), contains('the agent `dev`'));
    expect(read('$dir/CLAUDE.md'), '@AGENTS.md\n');
    final s = json.decode(read('$dir/.claude/settings.json')) as Map<String, Object?>;
    expect(s, {
      'permissions': {
        'allow': ['mcp__antenna', 'Bash(git:*)'],
      },
    });
    expect(File('$dir/.claude/settings.json.antenna-backup').existsSync(), isFalse, reason: 'there was no file');
    expect(git.runs.map((r) => r.$1).toSet(), {dir}, reason: 'git runs in the folder');
    expect(git.config, {'user.name': 'Robin Example', 'user.email': 'robin@example.com'});
    expect(tmp.listSync(recursive: true).where((e) => e.path.contains('.antenna-')), isEmpty,
        reason: 'no temporary file is left');

    // Once: a second plan finds everything in place and changes nothing.
    final again = await plan(dir, choice, own: true);
    expect(again.steps.every((s) => s is KeepFileStep), isTrue, reason: '${again.steps}');
    expect(again.nothingToDo, isTrue);
  });

  test('existing files are kept and the settings merged after a backup; Codex gets no CLAUDE.md', () async {
    final dir = tmp.path;
    File('$dir/AGENTS.md').writeAsStringSync('mine\n');
    Directory('$dir/.claude').createSync();
    const mine = '{"model": "x", "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Read(.env)"]}, "hooks": {}}';
    File('$dir/.claude/settings.json').writeAsStringSync(mine);
    final p = await plan(dir, const AgentSetupChoice(instructions: true, allow: {'antenna-cli'}), claudeCode: false);
    expect(p.steps.whereType<KeepFileStep>().single.path, '$dir/AGENTS.md');
    await applyAgentSetup(p, fs, git);

    expect(read('$dir/AGENTS.md'), 'mine\n');
    expect(File('$dir/CLAUDE.md').existsSync(), isFalse);
    final text = read('$dir/.claude/settings.json');
    expect(json.decode(text), {
      'model': 'x',
      'permissions': {
        'allow': ['Bash(ls:*)', 'Bash(antenna:*)'],
        'deny': ['Read(.env)'],
      },
      'hooks': <String, Object?>{},
    });
    expect(text.indexOf('"model"'), lessThan(text.indexOf('"hooks"')), reason: 'the order of the owner\'s keys stays');
    expect(read('$dir/.claude/settings.json.antenna-backup'), mine);
    expect(git.runs, isEmpty);
  });

  test('settings that are not strict JSON, or of another shape, are refused and not touched', () async {
    final dir = tmp.path;
    Directory('$dir/.claude').createSync();
    final file = File('$dir/.claude/settings.json');
    for (final (text, reason) in [
      ('{ // a comment\n "permissions": {} }', AgentSetupFailure.settingsNotJson),
      ('{"permissions": {"allow": ["git"],}}', AgentSetupFailure.settingsNotJson),
      ('["mcp__antenna"]', AgentSetupFailure.settingsNotObject),
      ('{"permissions": []}', AgentSetupFailure.permissionsNotObject),
      ('{"permissions": null}', AgentSetupFailure.permissionsNotObject),
      ('{"permissions": {"allow": "all"}}', AgentSetupFailure.allowNotList),
    ]) {
      file.writeAsStringSync(text);
      await expectLater(plan(dir, const AgentSetupChoice(allow: {'git'})),
          throwsA(isA<AgentSetupException>().having((e) => e.reason, 'reason', reason).having(
              (e) => e.path, 'path', file.path)),
          reason: text);
      expect(file.readAsStringSync(), text, reason: 'not touched: $text');
    }
    expect(File('$dir/.claude/settings.json.antenna-backup').existsSync(), isFalse);
    // Without rules ticked the file is not even looked at.
    final files = (await plan(dir, const AgentSetupChoice(instructions: true))).steps.whereType<WriteFileStep>();
    expect(files, hasLength(2));
  });

  test('a chosen folder that does not exist is refused (only the own one is made); a relative path is no folder',
      () async {
    await expectLater(plan('${tmp.path}/nowhere', const AgentSetupChoice(instructions: true)),
        throwsA(isA<AgentSetupException>().having((e) => e.reason, 'reason', AgentSetupFailure.notFolder)));
    expect(Directory('${tmp.path}/nowhere').existsSync(), isFalse);
    await expectLater(plan('relative/dir', const AgentSetupChoice(instructions: true)),
        throwsA(isA<AgentSetupException>().having((e) => e.reason, 'reason', AgentSetupFailure.notFolder)));
  });

  test('a new file is never written over another one, nor through a link at its name', () {
    final f = File('${tmp.path}/AGENTS.md')..writeAsStringSync('mine\n');
    expect(() => fs.writeNew(f.path, 'theirs'), throwsA(isA<FileSystemException>()));
    expect(f.readAsStringSync(), 'mine\n');
    final target = '${tmp.path}/elsewhere.md';
    Link('${tmp.path}/CLAUDE.md').createSync(target);
    expect(() => fs.writeNew('${tmp.path}/CLAUDE.md', 'x'), throwsA(isA<FileSystemException>()));
    expect(File(target).existsSync(), isFalse, reason: 'nothing is written through the link');
    // And the plan sees the link as a file that is there: kept.
    expect(fs.exists('${tmp.path}/CLAUDE.md'), isTrue);
  });

  test('apply stops at the first failure: git ending with an error leaves the settings unwritten', () async {
    final dir = tmp.path;
    git.exitCode = 128;
    final p = await plan(dir,
        const AgentSetupChoice(gitName: 'Robin Example', gitEmail: 'robin@example.com', allow: {'antenna-tools'}));
    await expectLater(
        applyAgentSetup(p, fs, git),
        throwsA(isA<AgentSetupException>()
            .having((e) => e.reason, 'reason', AgentSetupFailure.commandFailed)
            .having((e) => e.path, 'command', 'git init')
            .having((e) => e.exitCode, 'exit code', 128)));
    expect(git.runs, hasLength(1));
    expect(File('$dir/.claude/settings.json').existsSync(), isFalse);
  });

  test('replace swaps the file in one rename and leaves no temporary file', () {
    final f = File('${tmp.path}/settings.json')..writeAsStringSync('{}');
    fs.replace(f.path, '{"a": 1}\n');
    expect(f.readAsStringSync(), '{"a": 1}\n');
    expect(tmp.listSync().map((e) => e.path.split('/').last), ['settings.json']);
  });

  test('the real git: init, then the identity in the folder\'s own config', () async {
    final which = Process.runSync('/usr/bin/env', ['which', 'git']);
    if (which.exitCode != 0) {
      markTestSkipped('git is not installed here');
      return;
    }
    const real = ProcessAgentFolderGit();
    final dir = tmp.path;
    final p = planAgentSetup(await inspectAgentFolder(fs, real, dir, own: false),
        agent: 'dev',
        claudeCode: true,
        choice: const AgentSetupChoice(gitName: 'Robin Example', gitEmail: 'robin@example.com'));
    await applyAgentSetup(p, fs, real);
    expect(Directory('$dir/.git').existsSync(), isTrue);
    expect(await real.localConfig(dir, 'user.name'), 'Robin Example');
    expect(await real.localConfig(dir, 'user.email'), 'robin@example.com');
    final again = planAgentSetup(await inspectAgentFolder(fs, real, dir, own: false),
        agent: 'dev',
        claudeCode: true,
        choice: const AgentSetupChoice(gitName: 'Robin Example', gitEmail: 'robin@example.com'));
    expect(again.steps, isEmpty, reason: 'a value git already has is not set again');
  });
}
