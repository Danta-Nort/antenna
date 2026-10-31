// SPDX-License-Identifier: AGPL-3.0-only
// Finding agent CLIs from a window started by launchd (PATH=/usr/bin:/bin:/usr/sbin:/sbin): the folders the official
// installers use (Claude Code's ~/.local/bin and ~/.claude/local), the npm prefix from ~/.npmrc, the login shell's
// PATH read once in the background; a dangling symlink or a non-executable file does not end the search; and AI apps
// and Code mode get the same absolute path from the one locator.

import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/program_locator.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/ai_apps.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/code_mode.dart';
import 'package:antenna_desktop/state/owner_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

const _home = '/Users/alex';

/// The environment launchd gives an app started from Finder or the Dock.
const _launchd = {
  'HOME': _home,
  'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
  'SHELL': '/bin/zsh',
  'LANG': 'en_US.UTF-8',
};

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);

/// A Mac where only [installed] exist; AI apps and Code mode on a fake daemon.
Future<(AppModel, FakeAgentComputer)> _mac(Set<String> installed) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  final c = FakeAgentComputer(macos: true, installed: installed, env: _launchd);
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
    m.dispose();
  });
  // Start in Code mode needs the password for a new agent's token.
  m.scanAiApps(notify: false);
  return (m, c);
}

Future<String?> _startClaude(AppModel m) => m
    .startAgent(
      const AgentRunSpec(agent: 'claude-dev', cli: AgentCli.claude, workDir: '$_home/project'),
      auth: const PasswordAuth('correct horse battery'),
      create: const NewAgent(name: 'claude-dev', localLevel: 5),
    )
    .then((e) => e?.toString());

void main() {
  for (final where in ['$_home/.local/bin/claude', '$_home/.claude/local/claude']) {
    test('launchd PATH, Claude Code only at $where: AI apps finds it and Code mode starts that path', () async {
      final (m, c) = await _mac({where});
      final row = m.aiAppRow(aiAppDef(AiApp.claudeCode));
      expect(row.found, isTrue);
      expect(row.foundAt, where);
      expect(m.agentHost!.locate(AgentCli.claude), where);
      expect(await _startClaude(m), isNull);
      expect(c.launches.single.command.first, where, reason: 'the same path AI apps showed');
      // The agent's PATH has the program's folder first (an npm CLI needs its node there) and the searched folders.
      final path = c.launches.single.environment['PATH']!.split(':');
      expect(path.first, File(where).parent.path);
      expect(path, containsAll(['$_home/.local/bin', '/opt/homebrew/bin', '/usr/local/bin']));
    });
  }

  test('not installed anywhere: "Not found on this computer", and Start says the CLI was not found', () async {
    final (m, c) = await _mac({});
    final row = m.aiAppRow(aiAppDef(AiApp.claudeCode));
    expect(row.found, isFalse);
    expect(l10nFor('en').appsNotFound, 'Not found on this computer');
    final err = await _startClaude(m);
    expect(err, contains('noProgram'));
    expect(c.launches, isEmpty);
  });

  test('Codex and Gemini CLI in Homebrew, /usr/local and the npm prefix from ~/.npmrc', () {
    final files = {'/opt/homebrew/bin/codex', '/usr/local/bin/gemini', '$_home/.npm-custom/bin/grok'};
    final p = ProgramLocator(
      windows: false,
      env: _launchd,
      isExecutable: files.contains,
      readFile: (path) => path == '$_home/.npmrc' ? '# mine\nregistry=https://registry.npmjs.org/\nprefix = "~/.npm-custom"\n' : null,
    );
    expect(p.locate('codex'), '/opt/homebrew/bin/codex');
    expect(p.locate('gemini'), '/usr/local/bin/gemini');
    expect(p.locate('grok'), '$_home/.npm-custom/bin/grok');
    expect(p.locate('claude'), isNull);
    expect(p.locate('../claude'), isNull, reason: 'a name, not a path');
    // The window's own PATH comes first (a window started from a terminal has the terminal's PATH).
    final fromTerminal = ProgramLocator(
      windows: false,
      env: {..._launchd, 'PATH': '/usr/local/bin:/opt/homebrew/bin:/usr/bin'},
      isExecutable: {'/usr/local/bin/codex', '/opt/homebrew/bin/codex'}.contains,
      readFile: (_) => null,
    );
    expect(fromTerminal.locate('codex'), '/usr/local/bin/codex');
  });

  test('npmrc prefix: ~, \$HOME and \${HOME} expanded, quotes removed, comments and relative prefixes ignored', () {
    expect(npmrcPrefix('prefix=~/.npm-global', _home), '$_home/.npm-global');
    expect(npmrcPrefix("prefix = '\${HOME}/npm'", _home), '$_home/npm');
    expect(npmrcPrefix(r'prefix=$HOME/x', _home), '$_home/x');
    expect(npmrcPrefix('; prefix=/nope\n# prefix=/nope\ncache=/c', _home), isNull);
    expect(npmrcPrefix('prefix=relative/dir', _home), isNull);
  });

  test('the login shell PATH (nvm) is read once, in the background, and then the CLI is found', () async {
    final calls = <(String, List<String>)>[];
    final files = {'$_home/.nvm/versions/node/v22.11.0/bin/gemini', '/bin/zsh'};
    final p = ProgramLocator(
      windows: false,
      env: _launchd,
      isExecutable: files.contains,
      readFile: (_) => null,
      loginShell: (shell, args, timeout) async {
        calls.add((shell, args));
        expect(timeout, loginShellTimeout);
        // A profile may print anything (a greeting, a prompt); only the marked lines count.
        return 'Last login: Mon Oct  5 09:12:44\n'
            '__ANTENNA_PATH__$_home/.nvm/versions/node/v22.11.0/bin:/usr/bin:/bin\n'
            '__ANTENNA_NPM__$_home/.nvm/versions/node/v22.11.0\n';
      },
    );
    expect(p.locate('gemini'), isNull, reason: 'not before the login shell answered');
    expect(p.loginShellLoaded, isFalse);
    expect(await p.loadLoginShell(), isTrue, reason: 'it added folders');
    expect(p.locate('gemini'), '$_home/.nvm/versions/node/v22.11.0/bin/gemini');
    expect(await p.loadLoginShell(), isTrue, reason: 'the same answer, not a second run');
    expect(calls, hasLength(1));
    expect(calls.single.$1, '/bin/zsh', reason: r'$SHELL');
    expect(calls.single.$2, ['-ilc', loginShellScript]);
  });

  test('a login shell that fails or times out changes nothing; no shell runs without a runner', () async {
    final failed = ProgramLocator(
        windows: false,
        env: _launchd, isExecutable: {'/bin/zsh'}.contains, readFile: (_) => null, loginShell: (_, _, _) async => null);
    expect(await failed.loadLoginShell(), isFalse);
    expect(failed.loginShellLoaded, isTrue);
    final none = ProgramLocator(windows: false, env: _launchd, isExecutable: (_) => false, readFile: (_) => null);
    expect(await none.loadLoginShell(), isFalse);
  });

  test('the script prints the PATH and the npm prefix between markers (a real /bin/sh)', () async {
    final out = await runLoginShell('/bin/sh', ['-c', loginShellScript], const Duration(seconds: 10));
    expect(out, isNotNull);
    final line = out!.split('\n').firstWhere((l) => l.startsWith('__ANTENNA_PATH__'));
    expect(line.substring('__ANTENNA_PATH__'.length), Platform.environment['PATH']);
    expect(out, contains('__ANTENNA_NPM__'));
    // A shell that never ends is killed at the limit.
    final sw = Stopwatch()..start();
    expect(await runLoginShell('/bin/sh', ['-c', 'sleep 30'], const Duration(milliseconds: 300)), isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  }, skip: Platform.isWindows);

  test('a dangling symlink or a non-executable file does not stop the search (real files)', () {
    final root = Directory.systemTemp.createTempSync('antenna-locator-');
    addTearDown(() => root.deleteSync(recursive: true));
    final a = Directory('${root.path}/a')..createSync();
    final b = Directory('${root.path}/b')..createSync();
    final c = Directory('${root.path}/c')..createSync();
    // An updater removed the version the link points to.
    Link('${a.path}/claude').createSync('${root.path}/versions/2.0.1');
    File('${b.path}/claude').writeAsStringSync('not a program');
    final real = File('${c.path}/claude')..writeAsStringSync('#!/bin/sh\necho claude\n');
    Process.runSync('chmod', ['755', real.path]);
    // The native installer's layout: ~/.local/bin/claude → ~/.local/share/claude/versions/<version>.
    final v = File('${root.path}/versions/2.0.2')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    Process.runSync('chmod', ['755', v.path]);
    Link('${root.path}/linked').createSync(v.path);
    final p = ProgramLocator(
      windows: false,
      env: {'HOME': root.path, 'PATH': '${a.path}:${b.path}:${c.path}'},
      readFile: (_) => null,
    );
    expect(p.locate('claude'), real.path);
    expect(isExecutableFile('${root.path}/linked'), isTrue, reason: 'a symlink to a live version counts');
    expect(isExecutableFile('${a.path}/claude'), isFalse);
    expect(isExecutableFile('${b.path}/claude'), isFalse);
  }, skip: Platform.isWindows);

  test('the core binaries outside the bundle use the same folders', () {
    final core = locateCore(
      env: _launchd,
      executable: '/Applications/Antenna.app/Contents/MacOS/Antenna',
      exists: {'$_home/.local/bin/antennad', '$_home/.local/bin/antenna'}.contains,
      os: 'macos',
    );
    expect(core.daemon, '$_home/.local/bin/antennad');
    expect(core.cli, '$_home/.local/bin/antenna');
  });

  // T13: the Windows branch, on a file system of its own (the same on every test machine).
  group('Windows', () {
    const profile = r'C:\Users\o';
    const npm = r'C:\Users\o\AppData\Roaming\npm';
    const env = {
      // Windows spells it `Path`; the name counts in any case.
      'Path': r'C:\Windows\System32;relative\bin;C:\Program Files\nodejs\;C:\tools',
      'USERPROFILE': profile,
      'APPDATA': r'C:\Users\o\AppData\Roaming',
    };
    const modules = '$npm\\node_modules';
    const codexPackage = '$modules\\@openai\\codex';
    const claudePackage = '$modules\\@anthropic-ai\\claude-code';
    const node = r'C:\Program Files\nodejs\node.exe';
    ProgramLocator locator(Set<String> files, {Map<String, String> packages = const {}}) => ProgramLocator(
          env: env,
          windows: true,
          isExecutable: files.contains,
          readFile: (path) => packages[path],
          listDir: (dir) => switch (dir) {
            modules => ['.bin', '@openai', '@anthropic-ai', 'left-pad'],
            '$modules\\@openai' => ['codex'],
            '$modules\\@anthropic-ai' => ['claude-code'],
            _ => const [],
          },
        );
    const packages = {
      '$codexPackage\\package.json': '{"name":"@openai/codex","bin":{"codex":"bin/codex.js"}}',
      '$claudePackage\\package.json': '{"name":"@anthropic-ai/claude-code","bin":{"claude":"cli.js"}}',
      '$modules\\left-pad\\package.json': '{"name":"left-pad"}',
    };

    test('the search: Path split on ";" (absolute folders only), then .local\\bin and the npm prefix', () {
      expect(locator(const {}).searchDirs, [
        r'C:\Windows\System32',
        r'C:\Program Files\nodejs',
        r'C:\tools',
        '$profile\\.local\\bin',
        npm,
      ]);
      expect(locator(const {}).home, profile);
    });

    test('a native .exe wins; an npm install runs as node.exe and its script; a .cmd is never returned', () {
      final files = {
        node,
        '$profile\\.local\\bin\\claude.exe',
        '$npm\\claude.cmd',
        '$claudePackage\\cli.js',
        '$npm\\codex.cmd',
        '$codexPackage\\bin\\codex.js',
      };
      final p = locator(files, packages: packages);
      expect(p.launchOf('claude'), const NativeProgram('$profile\\.local\\bin\\claude.exe'));
      expect(p.launchOf('codex'), const NodeProgram(node: node, script: '$codexPackage\\bin\\codex.js'));
      expect(p.locate('codex'), isNull, reason: 'its .cmd is not a program of its own');
      expect(p.locate('node'), node);
      expect(p.locate(r'..\claude'), isNull, reason: 'a name, not a path');
      // node.exe next to the shim wins over the one on Path (npm's own layout).
      final local = locator({...files, '$npm\\node.exe'}, packages: packages);
      expect(
        local.launchOf('codex'),
        const NodeProgram(node: '$npm\\node.exe', script: '$codexPackage\\bin\\codex.js'),
      );
    });

    test('control: a .cmd with no package behind it, or no node.exe, is not started, and says why', () {
      final noPackage = locator({node, '$npm\\codex.cmd'});
      expect(noPackage.launchOf('codex'), isA<ShimOnly>().having((s) => s.why, 'why', contains('no package')));
      final noNode = locator({'$npm\\codex.cmd', '$codexPackage\\bin\\codex.js'}, packages: packages);
      expect(noNode.launchOf('codex'), isA<ShimOnly>().having((s) => s.why, 'why', contains('node.exe')));
      expect(locator(const {}).launchOf('codex'), isNull);
      // A bin that climbs out of its package is not taken.
      final climbing = locator({node, '$npm\\codex.cmd', '$modules\\evil.js'}, packages: {
        '$codexPackage\\package.json': r'{"name":"@openai/codex","bin":{"codex":"..\\..\\evil.js"}}',
      });
      expect(climbing.launchOf('codex'), isA<ShimOnly>());
    });

    test('control: the same locator off Windows finds programs as before', () {
      final p = ProgramLocator(
        windows: false,
        env: const {'HOME': '/home/o', 'PATH': '/usr/local/bin:/usr/bin'},
        isExecutable: {'/usr/local/bin/codex'}.contains,
        readFile: (_) => null,
      );
      expect(p.launchOf('codex'), const NativeProgram('/usr/local/bin/codex'));
      expect(p.launchOf('claude'), isNull);
    });
  });
}
