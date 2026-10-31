// SPDX-License-Identifier: AGPL-3.0-only
// "Install <app>" in the Check panel (D-110): the vendor's own command is shown first with where it comes from, nothing
// runs before Run, then it runs in a terminal in the window, in the owner's login shell, without any of Antenna's
// variables or an agent token, and the owner sees what it prints, can stop it and check again.

import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/ai_apps.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/cli_installer.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);

/// A computer without Claude Code or Codex, as a Mac user's window would see it after being started from a terminal
/// of another agent session (its markers and a token in the window's environment).
FakeAgentComputer _computer() => FakeAgentComputer(
      installed: const {'/bin/bash', '/bin/zsh'},
      env: const {
        'HOME': '/Users/owner',
        'SHELL': '/bin/zsh',
        'PATH': '/usr/bin:/bin',
        'LANG': 'en_US.UTF-8',
        'ANTENNA_AGENT_TOKEN': 'xat_SOMEAGENT',
        'ANTENNA_SOCKET': '/Users/owner/.local/share/antenna/antennad.sock',
        'CLAUDECODE': '1',
      },
    );

Future<(AppModel, FakeAgentComputer, FakeAppLauncher)> _panel(WidgetTester t) async {
  final launcher = FakeAppLauncher();
  final c = _computer();
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  final m = AppModel(
      connector: (_) => d,
      socketPath: d.socketPath,
      live: false,
      clock: () => fixedNow,
      binaries: _bins,
      agentHost: c.host,
      connectorFs: FakeConnectorFs(),
      appLauncher: launcher);
  await m.connect();
  t.view.physicalSize = const Size(1440, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance()));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('nav-settings')));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('settings-check')));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
  return (m, c, launcher);
}

Future<void> _openDialog(WidgetTester t, String app) async {
  final b = find.byKey(Key('check-fix-run-install-$app'));
  await t.ensureVisible(b);
  await t.pump();
  await t.tap(b);
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  test('every install command is the vendor\'s own: one fixed line from its own site, with the page it is from', () {
    final hosts = {
      AiApp.claudeCode: ('https://claude.ai/', 'https://code.claude.com/'),
      AiApp.codex: ('https://chatgpt.com/', 'https://learn.chatgpt.com/'),
      AiApp.geminiCli: ('@google/gemini-cli', 'https://github.com/google-gemini/'),
      AiApp.grok: ('https://x.ai/', 'https://docs.x.ai/'),
    };
    for (final a in aiApps) {
      final i = a.install;
      if (i == null) {
        expect(hosts.containsKey(a.id), isFalse, reason: a.name);
        continue;
      }
      final (inCommand, page) = hosts[a.id]!;
      expect(i.command, contains(inCommand), reason: a.name);
      expect(i.source, startsWith(page), reason: a.name);
      expect(i.command.contains('\n') || i.command.contains(';'), isFalse, reason: 'one line: ${a.name}');
      expect(i.checked, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    }
    expect(aiAppDef(AiApp.claudeCode).install!.command, 'curl -fsSL https://claude.ai/install.sh | bash');
    expect(aiAppDef(AiApp.codex).install!.command, 'curl -fsSL https://chatgpt.com/codex/install.sh | sh');
  });

  testWidgets('the command is shown first; Cancel runs nothing', (t) async {
    final (m, c, _) = await _panel(t);
    await _openDialog(t, 'codex');
    expect(find.text('curl -fsSL https://chatgpt.com/codex/install.sh | sh'), findsOneWidget);
    expect(find.textContaining('https://learn.chatgpt.com/docs/codex/cli'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    expect(c.ptys, isEmpty, reason: 'nothing runs before Run');
    await t.tap(find.text('Cancel'));
    await t.pump(const Duration(milliseconds: 300));
    expect(c.ptys, isEmpty);
    m.dispose();
  });

  testWidgets('Run: the command in the owner\'s login shell, in a terminal, without Antenna\'s variables; the output '
      'shows; when it ends, Check again', (t) async {
    final (m, c, _) = await _panel(t);
    await _openDialog(t, 'claudeCode');
    await t.tap(find.byKey(const Key('check-install-run')));
    await t.pump(const Duration(milliseconds: 300));
    expect(c.ptys, hasLength(1));
    final launch = c.last.launch;
    expect(launch.command, ['/bin/zsh', '-l', '-c', 'curl -fsSL https://claude.ai/install.sh | bash']);
    expect(launch.arguments.take(4), ['-c', agentWrapperScript, agentWrapperName, '/Users/owner']);
    expect(launch.environment.keys.where((k) => k.startsWith('ANTENNA_') && k != agentEnvUnsetVar), isEmpty);
    final unset = launch.environment[agentEnvUnsetVar]!.split(' ');
    expect(unset, containsAll(['ANTENNA_AGENT_TOKEN', 'ANTENNA_SOCKET', 'CLAUDECODE']));
    expect(unset, isNot(contains('HOME')));
    expect('$launch ${launch.arguments.join(' ')}', isNot(contains('xat_')));
    // What it prints is on screen
    c.last.emit('Setting up Claude Code...\r\n✔ Claude Code successfully installed!\r\n');
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('check-install-stop')), findsOneWidget);
    c.last.emit('\x1b]6973;0\x07');
    c.last.end(0);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Finished. Claude Code is installed: check again to see it.'), findsOneWidget);
    await t.tap(find.byKey(const Key('check-install-check')));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.byKey(const Key('check-install-terminal')), findsNothing, reason: 'the dialog closed after the check');
    m.dispose();
  });

  testWidgets('an installer that fails says its code; Stop ends a running one like closing a terminal', (t) async {
    final (m, c, _) = await _panel(t);
    await _openDialog(t, 'codex');
    await t.tap(find.byKey(const Key('check-install-run')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('check-install-stop')));
    await t.pump(const Duration(milliseconds: 300));
    expect(c.last.signals, [ProcessSignal.sighup]);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('The installer ended with code'), findsOneWidget);
    m.dispose();
  });

  test('the login shell: SHELL when it is a known shell this computer has, else the wrapper\'s', () {
    bool has(String p) => {'/bin/zsh', '/bin/bash', '/opt/homebrew/bin/fish'}.contains(p);
    expect(installShell({'SHELL': '/bin/zsh'}, '/bin/bash', exists: has), '/bin/zsh');
    expect(installShell({'SHELL': '/opt/homebrew/bin/fish'}, '/bin/bash', exists: has), '/opt/homebrew/bin/fish');
    expect(installShell({'SHELL': '/usr/bin/python3'}, '/bin/bash', exists: has), '/bin/bash');
    expect(installShell({'SHELL': 'zsh'}, '/bin/bash', exists: has), '/bin/bash');
    expect(installShell({}, '/bin/bash', exists: has), '/bin/bash');
  });

  test('under a real bash: the installer gets the user\'s context and none of Antenna\'s variables', () async {
    final dir = Directory.systemTemp.createTempSync('antenna-install-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final env = {
      'HOME': dir.path,
      'PATH': '/usr/bin:/bin',
      'LANG': 'C.UTF-8',
      'ANTENNA_AGENT_TOKEN': 'xat_SOMEAGENT',
      'ANTENNA_AGENT_TOKEN_FILE': '/x/agent.token',
      'ANTENNA_SOCKET': '/x/antennad.sock',
      'CLAUDECODE': '1',
    };
    final l = buildInstallLaunch(
      install: const VendorInstall('env', source: 'https://example.com', checked: '2026-10-06'),
      shell: '/bin/bash',
      loginShell: '/bin/sh',
      home: dir.path,
      env: env,
      searchDirs: const ['/usr/bin', '/bin'],
    );
    final r = await Process.run(l.executable, l.arguments,
        environment: {...env, ...l.environment}, includeParentEnvironment: false);
    final out = '${r.stdout}';
    expect(out, contains('HOME=${dir.path}'));
    for (final v in ['ANTENNA_AGENT_TOKEN', 'ANTENNA_AGENT_TOKEN_FILE', 'ANTENNA_SOCKET', 'CLAUDECODE', 'ANTENNA_UNSET']) {
      expect(out, isNot(contains('$v=')), reason: v);
    }
    expect(out, contains('\x1b]6973;0\x07'), reason: 'the exit code through the terminal');
  });
}
