// SPDX-License-Identifier: AGPL-3.0-only
// The Check panel (D-96 phase 1, D-UI-26): each check on its inputs, and each fix as the owner sees it, on the fake
// daemon, a fake computer and a real temporary home folder for the shell profile: the daemon down → Start; the keys
// locked → Unlock with the password; links without their relay → the facts, `antenna doctor`, the local network; an AI
// app's program missing → the vendor's install guide; not on PATH → one profile line after consent and a backup, then
// found; an app that has not started Antenna since Connect → its own Quit and open; a process refused because another
// holds the agent's token → an agent of its own. Every fix is an owner action; nothing reaches agents.

import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/daemon_host.dart';
import 'package:antenna_desktop/host/shell_path.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_launch.dart' show AgentCli;
import 'package:antenna_desktop/state/ai_apps.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/doctor.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/fake_host.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);

const _relayUrl = 'https://euc1-1.relay.n0.iroh.link./';

void main() {
  group('the checks', () {
    test('daemon: down (the window can start it, or not), connecting, running', () {
      final down = checkDaemon(Phase.unreachable, canStart: true, socket: '/s');
      expect((down.state, down.code, down.canStart), (CheckState.problem, 'daemon_down', true));
      expect(checkDaemon(Phase.unreachable, canStart: false, socket: '/s').canStart, isFalse);
      expect(checkDaemon(Phase.connecting, canStart: true, socket: '/s').state, CheckState.unknown);
      final ok = checkDaemon(Phase.unlocked,
          canStart: true,
          socket: '/s',
          hello: const HelloOk(daemon: 'antennad 0.1.0', protocol: '1', state: DaemonState.unlocked, proto: 'x-control/6'));
      expect((ok.state, ok.code, ok.daemon, ok.protocol), (CheckState.ok, null, 'antennad 0.1.0', 'x-control/6'));
    });

    test('keys: locked and signed out are problems; not set up is information', () {
      expect(checkKeys(Phase.locked).code, 'keys_locked');
      expect((checkKeys(Phase.loginRequired).state, checkKeys(Phase.loginRequired).signIn), (CheckState.problem, true));
      expect(checkKeys(Phase.unlocked).state, CheckState.ok);
      expect(checkKeys(Phase.uninitialized).state, CheckState.info);
      expect(checkKeys(Phase.unreachable).state, CheckState.unknown);
    });

    test('relay: links without it, relay-only marked; all connected; disabled; an older daemon; locked', () {
      final up = contact('Emily Carter', 1, homeRelay: const HomeRelayInfo(url: _relayUrl, connected: true));
      // Relay-only (trust ≤ 2) has no other path: its relay down means it really cannot connect (`connected: false`
      // is the only state physically possible for it here; PG-32 does not change that).
      final downRelayOnly = contact('Rachel', 2,
          trust: 2,
          connected: false,
          homeRelay: const HomeRelayInfo(url: _relayUrl, connected: false, error: 'connect: timed out'));
      final r = checkRelay(Phase.unlocked,
          status: const StatusReply(state: DaemonState.unlocked, daemon: 'd', protocol: '1', relay: 'n0'),
          contacts: [up, downRelayOnly]);
      expect((r.state, r.code, r.connected, r.down.single.contact, r.down.single.relayOnly, r.down.single.error),
          (CheckState.problem, 'relay_unreachable', 1, 'Rachel', true, 'connect: timed out'));
      // PG-32: trust 3+ over the local network, relay down, link itself up — not a finding (negative control: drop
      // `&& !c.transport.connected` in checkRelay and this contact reappears in `down`).
      final lanOnly = contact('Aisha', 4,
          trust: 4,
          connected: true,
          homeRelay: const HomeRelayInfo(url: _relayUrl, connected: false, error: 'network unreachable'));
      expect(checkRelay(Phase.unlocked, contacts: [lanOnly]).state, CheckState.ok);
      expect(checkRelay(Phase.unlocked, contacts: [up]).state, CheckState.ok);
      expect(checkRelay(Phase.unlocked, contacts: const []).state, CheckState.ok);
      final disabled = checkRelay(Phase.unlocked,
          status: const StatusReply(state: DaemonState.unlocked, daemon: 'd', protocol: '1', relay: 'disabled'),
          contacts: [contact('Rachel', 2, trust: 2)]);
      expect((disabled.state, disabled.code, disabled.relayOnlyContacts), (CheckState.problem, 'relay_disabled', 1));
      final older = checkRelay(Phase.unlocked, contacts: [contact('Emily Carter', 1)]);
      expect((older.state, older.reason), (CheckState.unknown, UnknownReason.olderDaemon));
      expect(checkRelay(Phase.locked, contacts: const []).reason, UnknownReason.locked);
      expect(checkRelay(Phase.unreachable, contacts: const []).reason, UnknownReason.noDaemon);
    });

    test('an AI app\'s program: on PATH, off PATH with the fix, missing (used or not), PATH not readable', () {
      CliCheck cli({String? at, List<String>? login, bool chosen = true}) => checkCli(aiAppDef(AiApp.claudeCode),
          locate: (n) => n == 'claude' ? at : null,
          searched: const ['/usr/bin', '/home/sam/.local/bin'],
          loginPath: login,
          chosen: chosen,
          shell: '/bin/zsh',
          home: '/home/sam',
          macos: false);
      expect(cli(at: '/usr/bin/claude', login: ['/usr/bin']).state, CheckState.ok);
      final off = cli(at: '/home/sam/.local/bin/claude', login: ['/usr/bin']);
      expect((off.state, off.code, off.folder), (CheckState.problem, 'ai_cli_not_on_path', '/home/sam/.local/bin'));
      expect((off.fix!.profile, off.fix!.line), ('/home/sam/.zprofile', r'export PATH="$HOME/.local/bin:$PATH"'));
      final missing = cli();
      expect((missing.state, missing.code), (CheckState.problem, 'ai_cli_missing'));
      expect(missing.searched, ['/usr/bin', '/home/sam/.local/bin']);
      expect(cli(chosen: false).state, CheckState.info, reason: 'not used: worth knowing, not broken');
      expect(cli(at: '/usr/bin/claude').state, CheckState.unknown, reason: 'the login shell was not read');
    });

    test('tokens: a refused process that runs or was refused in the last 10 minutes; nothing else', () {
      AgentInfo agent({int? ms, bool? alive}) => AgentInfo(
            name: 'chatgpt',
            createdMs: 0,
            boundPid: 4242,
            boundComm: 'ChatGPT',
            boundAlive: true,
            refusedPid: ms == null ? null : 777,
            refusedComm: 'codex',
            refusedMs: ms,
            refusedAlive: alive,
          );
      final now = fixedNow;
      final live = checkTokens(Phase.unlocked,
          agents: [agent(ms: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch, alive: true)], now: now);
      expect((live.state, live.code), (CheckState.problem, 'token_bound_elsewhere'));
      final r = live.refusals.single;
      expect((r.agent, r.boundComm, r.boundPid, r.refusedComm, r.refusedPid, r.cli?.name), ('chatgpt', 'ChatGPT', 4242, 'codex', 777, 'codex'));
      expect(
          checkTokens(Phase.unlocked,
                  agents: [agent(ms: now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch, alive: false)], now: now)
              .state,
          CheckState.problem);
      expect(
          checkTokens(Phase.unlocked,
                  agents: [agent(ms: now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch, alive: false)], now: now)
              .state,
          CheckState.ok);
      expect(checkTokens(Phase.unlocked, agents: [agent()], now: now).state, CheckState.ok);
      expect(checkTokens(Phase.locked, agents: const [], now: now).reason, UnknownReason.locked);
    });
  });

  group('the PATH line', () {
    test('per shell: zsh, bash on macOS and Linux, fish, others', () {
      PathFix f(String shell, {bool macos = false}) =>
          pathFixFor('/Users/sam/.local/bin', shell: shell, home: '/Users/sam', macos: macos)!;
      expect(f('/bin/zsh').profile, '/Users/sam/.zprofile');
      expect(f('/bin/bash', macos: true).profile, '/Users/sam/.bash_profile');
      expect(f('/bin/bash').profile, '/Users/sam/.bashrc');
      expect((f('/opt/homebrew/bin/fish').profile, f('/opt/homebrew/bin/fish').line),
          ('/Users/sam/.config/fish/config.fish', r'fish_add_path $HOME/.local/bin'));
      expect(f('/bin/dash').profile, '/Users/sam/.profile');
      expect(pathFixFor('/opt/homebrew/bin', shell: '/bin/zsh', home: '/Users/sam', macos: true)!.line,
          r'export PATH="/opt/homebrew/bin:$PATH"');
    });

    test('a folder that is not plain text is never put into a shell line', () {
      for (final bad in [
        '/Users/sam/My Tools/bin',
        '/Users/sam/bin";rm -rf ~;"',
        r'/Users/sam/$(curl example.com)',
        '/Users/sam/`id`',
        '/Users/sam/bin\nexport EVIL=1',
        "/Users/sam/it's",
        '/Users/sam/../../etc',
        'relative/bin',
      ]) {
        expect(pathFixFor(bad, shell: '/bin/zsh', home: '/Users/sam', macos: true), isNull, reason: bad);
      }
    });

    test('appended once, after a backup; a profile that is a link stays a link', () {
      final home = Directory.systemTemp.createTempSync('antenna-path-');
      addTearDown(() => home.deleteSync(recursive: true));
      final dotfiles = File('${home.path}/dotfiles/zprofile')
        ..createSync(recursive: true)
        ..writeAsStringSync('export EDITOR=vim');
      Link('${home.path}/.zprofile').createSync(dotfiles.path);
      final fix = pathFixFor('${home.path}/.local/bin', shell: '/bin/zsh', home: home.path, macos: true)!;
      final (r, backup) = applyPathFix(fix, now: DateTime(2026, 10, 5, 12));
      expect(r, PathFixResult.added);
      expect(File(backup!).readAsStringSync(), 'export EDITOR=vim');
      expect(FileSystemEntity.isLinkSync('${home.path}/.zprofile'), isTrue);
      expect(dotfiles.readAsStringSync(),
          'export EDITOR=vim\n# Added by Antenna: ${home.path}/.local/bin on PATH for new terminals\n${fix.line}\n');
      expect(applyPathFix(fix).$1, PathFixResult.present);
      expect(RegExp(RegExp.escape(fix.line)).allMatches(dotfiles.readAsStringSync()), hasLength(1));
      // A profile that does not exist yet: created, no backup.
      final bash = pathFixFor('${home.path}/.local/bin', shell: '/bin/bash', home: home.path, macos: false)!;
      expect(applyPathFix(bash), (PathFixResult.added, null));
    });
  });

  group('the panel and its fixes', () {
    Future<void> show(WidgetTester t, AppModel m, {bool settings = false}) async {
      t.view.physicalSize = const Size(1440, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(XApp(model: m, appearance: Appearance()));
      await t.pump(const Duration(milliseconds: 300));
      if (settings) {
        await t.tap(find.byKey(const Key('nav-settings')));
        await t.pump(const Duration(milliseconds: 300));
        await t.tap(find.byKey(const Key('settings-check')));
        await t.pump(const Duration(milliseconds: 300));
      } else {
        await t.tap(find.byKey(const Key('gate-check')));
        await t.pump(const Duration(milliseconds: 300));
      }
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets('the daemon is down: from the sign-in screen, Start starts it, and the check turns green', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..reachable = false;
      final host = FakeHost(d);
      final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow, host: host)
        ..autoStartDaemon = false;
      await m.connect();
      expect(m.phase, Phase.unreachable);
      await show(t, m);
      expect(find.byKey(const Key('check-row-daemon')), findsOneWidget);
      expect(find.text('daemon_down'), findsOneWidget);
      await t.tap(find.byKey(const Key('check-fix-start')));
      await t.pump(const Duration(milliseconds: 300));
      expect(host.starts, 1);
      expect(m.checks.whereType<DaemonCheck>().single.state, CheckState.ok);
      m.dispose();
    });

    testWidgets('the keys are locked: Unlock asks the password, then unlocks', (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), state: DaemonState.locked);
      final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
      await m.connect();
      await show(t, m);
      expect(find.text('keys_locked'), findsOneWidget);
      await t.tap(find.byKey(const Key('check-fix-unlock')));
      await t.pump(const Duration(milliseconds: 300));
      await t.enterText(find.byKey(const Key('owner-password')), d.password);
      await t.tap(find.byKey(const Key('password-ok')));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(milliseconds: 300));
      expect(m.phase, Phase.unlocked);
      expect(m.checks.whereType<KeysCheck>().single.state, CheckState.ok);
      m.dispose();
    });

    testWidgets('links without their relay: who, which relay, why; `antenna doctor`; the local network as a fix '
        '(and PG-32: connected over LAN anyway is not shown)', (t) async {
      final d = FakeDaemon(contacts: [
        contact('Emily Carter', 1, homeRelay: const HomeRelayInfo(url: _relayUrl, connected: true)),
        contact('Rachel Brooks', 2,
            trust: 2,
            connected: false,
            homeRelay: const HomeRelayInfo(url: _relayUrl, connected: false, error: 'dns: no such host')),
        contact('Jordan Lee', 3,
            trust: 3,
            connected: false,
            homeRelay: const HomeRelayInfo(url: _relayUrl, connected: false, error: 'dns: no such host')),
        // PG-32 (SPEC scenario S13): relay down, but this link is up over the local network — no row for Priya.
        contact('Priya Nair', 4,
            trust: 4,
            connected: true,
            homeRelay: const HomeRelayInfo(url: _relayUrl, connected: false, error: 'dns: no such host')),
      ], history: demoHistory());
      final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
      await m.connect();
      await show(t, m, settings: true);
      expect(find.text('relay_unreachable'), findsOneWidget);
      expect(find.textContaining('Rachel Brooks · level 2 · relay only'), findsOneWidget);
      expect(find.textContaining('Jordan Lee · level 3\n'), findsOneWidget, reason: 'level 3+: not relay only');
      expect(find.textContaining('Priya Nair'), findsNothing, reason: 'connected over LAN: not a fault (PG-32)');
      expect(find.textContaining('dns: no such host'), findsNWidgets(2));
      expect(find.text('antenna doctor'), findsOneWidget);
      await t.tap(find.byKey(const Key('check-fix-lan')));
      await t.pump(const Duration(milliseconds: 300));
      await t.enterText(find.byKey(const Key('owner-password')), d.password);
      await t.tap(find.byKey(const Key('password-ok')));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.lanEnabled, isTrue);
      m.dispose();
    });

    testWidgets('a program not on PATH: the line is shown first, appended once, and the program is then found',
        (t) async {
      final home = Directory.systemTemp.createTempSync('antenna-doctor-');
      addTearDown(() => home.deleteSync(recursive: true));
      final bin = '${home.path}/.local/bin';
      Future<String?> loginShell(String shell, List<String> args, Duration timeout) async {
        final p = File('${home.path}/.zprofile');
        final on = p.existsSync() && p.readAsStringSync().contains(r'$HOME/.local/bin');
        return '\n__ANTENNA_PATH__/usr/bin:/bin${on ? ':$bin' : ''}\n__ANTENNA_NPM__\n';
      }

      final c = FakeAgentComputer(
        installed: {'$bin/claude', '/bin/zsh'},
        env: {'HOME': home.path, 'SHELL': '/bin/zsh', 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
        loginShell: loginShell,
      );
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
      final m = AppModel(
          connector: (_) => d,
          socketPath: d.socketPath,
          live: false,
          clock: () => fixedNow,
          binaries: _bins,
          agentHost: c.host,
          connectorFs: FakeConnectorFs(),
          appLauncher: FakeAppLauncher());
      await m.connect();
      await show(t, m, settings: true);
      expect(find.text('ai_cli_not_on_path'), findsOneWidget);
      await t.tap(find.byKey(const Key('check-fix-path-claudeCode')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('# Added by Antenna: $bin on PATH for new terminals\nexport PATH="\$HOME/.local/bin:\$PATH"'),
          findsOneWidget, reason: 'the exact lines, before anything is written');
      expect(File('${home.path}/.zprofile').existsSync(), isFalse);
      await t.tap(find.byKey(const Key('check-path-ok')));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(milliseconds: 300));
      expect(File('${home.path}/.zprofile').readAsStringSync(), contains(r'export PATH="$HOME/.local/bin:$PATH"'));
      final claude = m.checks.whereType<CliCheck>().firstWhere((x) => x.app.id == AiApp.claudeCode);
      expect(claude.state, CheckState.ok, reason: 'the login shell was read again');
      m.dispose();
    });

    testWidgets('a program missing: the vendor\'s install guide opens', (t) async {
      final launcher = FakeAppLauncher();
      final c = FakeAgentComputer(installed: const {});
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
      await show(t, m, settings: true);
      final install = find.byKey(const Key('check-fix-install-claudeCode'));
      await t.ensureVisible(install);
      await t.pump();
      await t.tap(install);
      await t.pump();
      expect(launcher.urls, ['https://code.claude.com/docs/en/setup']);
      expect(find.textContaining('Looked in:'), findsWidgets);
      m.dispose();
    });

    testWidgets('an app that has not started Antenna since Connect: Restart quits it (its own Quit) and opens it',
        (t) async {
      const appPath = '/Applications/Claude.app';
      final launcher = FakeAppLauncher()..running.add(appPath);
      final c = FakeAgentComputer(
          macos: true,
          installed: const {appPath},
          env: const {'HOME': '/Users/owner', 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'});
      final fs = FakeConnectorFs({
        '/Users/owner/Library/Application Support/Claude/claude_desktop_config.json':
            '{"mcpServers":{"antenna":{"command":"/Applications/Antenna.app/Contents/Helpers/antenna",'
                '"args":["mcp","--token-file","/Users/owner/.local/share/antenna/agents/claude-desktop.token"]}}}',
      });
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
        ..agentList = [const AgentInfo(name: 'claude-desktop', createdMs: 0)];
      final m = AppModel(
          connector: (_) => d,
          socketPath: d.socketPath,
          live: false,
          clock: () => fixedNow,
          binaries: _bins,
          agentHost: c.host,
          connectorFs: fs,
          appLauncher: launcher);
      await m.connect();
      await show(t, m, settings: true);
      expect(find.text('app_restart_needed'), findsOneWidget);
      final restart = find.byKey(const Key('check-fix-restart-claudeDesktop'));
      await t.ensureVisible(restart);
      await t.pump();
      await t.tap(restart);
      await t.pump(const Duration(milliseconds: 300));
      expect(launcher.appCalls, isEmpty, reason: 'asked first');
      await t.tap(find.byKey(const Key('check-restart-ok')));
      await t.pump(const Duration(milliseconds: 300));
      expect(launcher.appCalls, ['quit:$appPath', 'open:$appPath']);
      m.dispose();
    });

    testWidgets('a program refused because another holds the agent\'s token: who and when; an agent of its own',
        (t) async {
      final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
        ..agentList = [
          AgentInfo(
            name: 'chatgpt',
            createdMs: 0,
            boundPid: 4242,
            boundComm: 'ChatGPT',
            boundAlive: true,
            refusedPid: 777,
            refusedComm: 'codex',
            refusedMs: fixedNow.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch,
            refusedAlive: true,
          ),
        ];
      final m = AppModel(
          connector: (_) => d,
          socketPath: d.socketPath,
          live: false,
          clock: () => fixedNow,
          binaries: _bins,
          agentHost: FakeAgentComputer().host);
      await m.connect();
      await show(t, m, settings: true);
      expect(find.text('token_bound_elsewhere'), findsOneWidget);
      expect(find.textContaining('Agent “chatgpt” is in use by ChatGPT (pid 4242). codex (pid 777) tried the same agent'),
          findsOneWidget);
      final fix = find.byKey(const Key('check-fix-newagent-chatgpt'));
      await t.ensureVisible(fix);
      await t.pump();
      await t.tap(fix);
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('agent-name')), findsOneWidget, reason: 'Start agent, with a new agent');
      expect(t.widget<SegmentedButton<AgentCli>>(find.byKey(const Key('code-program'))).selected, {AgentCli.codex});
      m.dispose();
    });
  });

  test('every problem code is the documented one (docs/LOCAL-ASSISTANT.md §4.1)', () {
    expect(
        {
          checkDaemon(Phase.unreachable, canStart: true, socket: '/s').code,
          checkKeys(Phase.locked).code,
          checkRelay(Phase.unlocked,
                  contacts: [
                    contact('A', 1, connected: false, homeRelay: const HomeRelayInfo(url: _relayUrl, connected: false)),
                  ])
              .code,
        },
        {'daemon_down', 'keys_locked', 'relay_unreachable'});
    expect(const DaemonStartException(DaemonStartFailure.exited).reason, DaemonStartFailure.exited);
  });
}
