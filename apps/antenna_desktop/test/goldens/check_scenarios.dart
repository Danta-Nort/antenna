// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for the Check panel (D-UI-26) and the Code mode screenshot button (D-UI-27): Settings → Check on a Mac with
// several findings at once (a link without its relay, Claude Code not on PATH, an app that has not started Antenna
// since Connect, a program refused because another holds the agent's token), the dock right after a screenshot went
// into Claude Code's prompt, and the Screen Recording sheet a new build without the permission gets instead (D-UI-41).

part of 'scenarios.dart';

/// The Mac of the Check frame: Claude Code installed by its native installer in ~/.local/bin, which the login
/// shell's PATH lacks; Codex from Homebrew; Claude Desktop and ChatGPT apps.
FakeAgentComputer _checkMac() => FakeAgentComputer(
      macos: true,
      installed: const {
        '/Users/owner/.local/bin/claude',
        '/opt/homebrew/bin/codex',
        '/Applications/Claude.app',
        '/Applications/ChatGPT.app',
        '/bin/zsh',
      },
      env: const {'HOME': '/Users/owner', 'SHELL': '/bin/zsh', 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
      loginShell: (shell, args, timeout) async =>
          '\n__ANTENNA_PATH__/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\n__ANTENNA_NPM__\n',
    );

const _desktopConfig = '/Users/owner/Library/Application Support/Claude/claude_desktop_config.json';

Future<AppModel> _checkModel() async {
  final contacts = [
    for (final c in demoContacts())
      c.label == rachel.label
          ? contact(rachel.label, 41,
              trust: 1,
              presence: 'not_tracked',
              lamport: 3,
              connected: false,
              homeRelay: const HomeRelayInfo(
                  url: 'https://euc1-1.relay.n0.iroh.link./',
                  connected: false,
                  error: 'Failed to connect to relay server: dns lookup failed'))
          : c,
  ];
  final d = _demo(contacts: contacts)
    ..agentList = [
      const AgentInfo(name: 'claude-desktop', createdMs: 0, localLevel: 5),
      AgentInfo(
        name: 'chatgpt',
        createdMs: 0,
        localLevel: 3,
        boundPid: 4242,
        boundComm: 'ChatGPT',
        boundAlive: true,
        refusedPid: 51877,
        refusedComm: 'codex',
        refusedMs: fixedNow.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch,
        refusedAlive: true,
      ),
    ];
  final pc = _checkMac();
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
    agentHost: pc.host,
    connectorFs: FakeConnectorFs({
      _desktopConfig: '{"mcpServers":{"antenna":{"command":"/Applications/Antenna.app/Contents/Helpers/antenna",'
          '"args":["mcp","--token-file","/Users/owner/Library/Application Support/Antenna/agents/claude-desktop.token"]}}}',
    }),
    appLauncher: FakeAppLauncher()..running.add('/Applications/Claude.app'),
  );
  await m.connect();
  return m;
}

Future<void> _checkFrame(WidgetTester t, Widget app) async {
  await _frame(t, app);
  await t.tap(find.byKey(const Key('nav-settings')));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('settings-check')));
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
  // The rows with problems first on screen: the relay row.
  await t.drag(find.byKey(const Key('check-panel')), const Offset(0, -300));
  await t.pump(const Duration(milliseconds: 400));
}

/// A Mac where Claude Code is not installed yet (Codex from Homebrew).
Future<AppModel> _installModel() async {
  final pc = FakeAgentComputer(
    macos: true,
    installed: const {'/opt/homebrew/bin/codex', '/bin/zsh', '/bin/bash'},
    env: const {'HOME': '/Users/owner', 'SHELL': '/bin/zsh', 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    loginShell: (shell, args, timeout) async =>
        '\n__ANTENNA_PATH__/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\n__ANTENNA_NPM__\n',
  );
  final d = _demo();
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
    agentHost: pc.host,
    connectorFs: FakeConnectorFs(),
    appLauncher: FakeAppLauncher(),
  );
  await m.connect();
  return m;
}

void _defineCheckScenarios() {
  // "Install Claude Code" from the Check panel (D-110): the vendor's command shown before anything runs.
  _s('82_install_cli', (t) async {
    const name = '82_install_cli';
    final m = await _installModel();
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('settings-check')));
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));
    final b = find.byKey(const Key('check-fix-run-install-claudeCode'));
    await t.ensureVisible(b);
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(b);
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('54_check_panel', (t) async {
    const name = '54_check_panel';
    final m = await _checkModel();
    await _checkFrame(t, XApp(model: m));
    await _snap(t, name);
  });

  _s('54_check_panel_dark', (t) async {
    const name = '54_check_panel_dark';
    final m = await _checkModel();
    await _checkFrame(t, _dark(m));
    await _snap(t, name);
  });

  // The dock right after "Screenshot": the image went into Claude Code's prompt as "[Image #1]".
  _s('55_code_screenshot', (t) async {
    const name = '55_code_screenshot';
    final dir = Directory.systemTemp.createTempSync('antenna-shot-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pc = FakeAgentComputer(
      macos: true,
      installed: const {'/Users/owner/.local/bin/claude', '/opt/homebrew/bin/codex'},
      env: const {'HOME': '/Users/owner', 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8'},
      hooks: true,
      shots: ScreenshotStore('${dir.path}/screenshots'),
      capture: FakeCapture(),
    );
    final m = await _codeWindow(pc);
    await _frame(t, XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    final rule = '─' * 40;
    String screen(String prompt) =>
        '\x1b[?2004h\x1b[2J\x1b[H$_claudeSession\r\n$rule\r\n> $prompt\r\n$rule\r\n  ? for shortcuts';
    pc.last.emit(screen(''));
    pc.hookChannels.last.emit(ClaudeHookEvent.stop);
    await t.pump();
    await t.tap(find.byKey(const Key('code-shot')));
    await t.pump();
    // What Claude Code draws after the paste.
    pc.last.emit(screen('[Image #1] '));
    await t.pump();
    // The confirmation goes; the bar with the button stays.
    for (final s in t.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      s.removeCurrentSnackBar();
    }
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
    m.disposeCodeWake();
    for (final r in m.runs) {
      r.kill();
    }
  });

  // "Screenshot" on a Mac whose new build has no Screen Recording (D-UI-41): the window's own sheet, before any tool.
  _s('91_screen_permission', (t) async {
    const name = '91_screen_permission';
    final dir = Directory.systemTemp.createTempSync('antenna-shot-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pc = FakeAgentComputer(
      macos: true,
      installed: const {'/Users/owner/.local/bin/claude', '/opt/homebrew/bin/codex'},
      env: const {'HOME': '/Users/owner', 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8'},
      hooks: true,
      shots: ScreenshotStore('${dir.path}/screenshots'),
      capture: FakeCapture(),
      screenPermission: FakeScreenPermission(ScreenPermission.missing),
    );
    final m = await _codeWindow(pc);
    await _frame(t, XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    final rule = '─' * 40;
    pc.last.emit('\x1b[?2004h\x1b[2J\x1b[H$_claudeSession\r\n$rule\r\n> \r\n$rule\r\n  ? for shortcuts');
    pc.hookChannels.last.emit(ClaudeHookEvent.stop);
    await t.pump();
    await t.tap(find.byKey(const Key('code-shot')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
    m.disposeCodeWake();
    for (final r in m.runs) {
      r.kill();
    }
  });
}
