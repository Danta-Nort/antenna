// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for Code mode: the window with the agents' terminals (light and dark), "Start agent", the Agents section
// with the AI apps found on a Mac and the role preset, and the terminal's text attributes. The terminal shows demo
// output written into a fake pseudo-terminal (no real program runs in a golden).

part of 'scenarios.dart';

/// A Mac with Claude Code (CLI), Codex, Claude Desktop and Cursor installed.
FakeAgentComputer _mac() => FakeAgentComputer(
      macos: true,
      installed: const {
        '/Users/owner/.local/bin/claude',
        '/opt/homebrew/bin/codex',
        '/Applications/Claude.app',
        '/Applications/Cursor.app',
      },
      env: const {'HOME': '/Users/owner', 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8'},
    );

Future<AppModel> _codeModel(FakeDaemon d, FakeAgentComputer pc) async {
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
    agentHost: pc.host,
  );
  await m.connect();
  return m;
}

List<AgentInfo> _codeAgents() => [
      AgentInfo(name: 'claude-backend', createdMs: 0, localLevel: 4, links: [jordanName, buildBotName]),
      AgentInfo(name: 'codex-infra', createdMs: 0, localLevel: 3, links: [buildBotName]),
    ];

// Demo output: bold, dim and colors as a CLI writes them; plain characters only (the bundled monospaced font).
const _b = '\x1b[1m';
const _d = '\x1b[2m';
const _g = '\x1b[32m';
const _y = '\x1b[33m';
const _c = '\x1b[36m';
const _r = '\x1b[0m';

String get _claudeSession => [
      '$_d cwd: ~/projects/antenna$_r',
      '',
      '$_c>$_r Jordan asked for the preview.4 build. Build it and send her the .dmg.',
      '',
      '$_g*$_r ${_b}antenna.read_inbox$_r',
      '  ${_d}1 message from Jordan Lee (level 3): "Can you send me the preview.4 build?"$_r',
      '',
      '$_g*$_r ${_b}Bash$_r packaging/macos/build-dmg.sh',
      '  ${_d}core 3m02s, window 41s, signed$_r',
      '  Built dist/Antenna-0.1.0-preview.4-macos-arm64.dmg (51.6 MB)',
      '',
      '$_g*$_r ${_b}antenna.share_file$_r Jordan Lee, dist/Antenna-0.1.0-preview.4-macos-arm64.dmg',
      '  ${_y}Waiting for the owner\'s approval in Antenna:$_r',
      '  ${_y}the file is outside the link folder.$_r',
      '',
      '$_c>$_r ',
    ].join('\r\n');

String get _codexSession => [
      '$_d workdir: ~/projects/infra$_r',
      '',
      '$_c>$_r Check the build bot disk and clean old artifacts.',
      '',
      '$_g*$_r ${_b}exec$_r df -h /srv/builds',
      '  /dev/sdb1  500G  412G  88G  83% /srv/builds',
      '$_g*$_r ${_b}exec$_r find /srv/builds -mtime +14 -delete',
      '  Freed 61 GB. Disk at 71 %.',
      '$_g*$_r ${_b}antenna.send_message$_r Build bot: "Cleaned 61 GB, disk at 71 %."',
      '',
      '${_d}Done.$_r',
      '',
    ].join('\r\n');

/// Claude Code after the window woke it: the built-in line it got, and what it did (the message itself it read over
/// MCP).
String get _claudeWoken => [
      '$_d cwd: ~/projects/antenna$_r',
      '',
      '$_c>$_r New Antenna messages from Jordan Lee: read your inbox and continue.',
      '',
      '$_g*$_r ${_b}antenna.read_inbox$_r',
      '  ${_d}1 message from Jordan Lee (level 3): "The preview.4 build installs fine. Add the release notes?"$_r',
      '',
      '$_g*$_r ${_b}Read$_r docs/RELEASE-NOTES.md',
      '$_g*$_r ${_b}antenna.send_message$_r Jordan Lee: "Release notes for preview.4 are in the thread."',
      '',
      '─' * 40,
      '$_c>$_r ',
      '─' * 40,
      '  $_d? for shortcuts$_r',
    ].join('\r\n');

/// Two agents in the dock: Claude Code running (active tab), Codex finished. The running agent's output is written by
/// [_codeFrame] once the terminal has its size, as a real program's output would be.
Future<AppModel> _codeWindow(FakeAgentComputer pc) async {
  final d = _demo()..agentList = _codeAgents();
  final m = await _codeModel(d, pc);
  await m.startAgent(
    const AgentRunSpec(agent: 'codex-infra', cli: AgentCli.codex, workDir: '/Users/owner/projects/infra'),
    auth: PasswordAuth(d.password),
  );
  pc.last
    ..emit(_codexSession)
    ..emit('\x1b]6973;0\x07')
    ..end(0);
  await m.startAgent(
    const AgentRunSpec(agent: 'claude-backend', cli: AgentCli.claude, workDir: '/Users/owner/projects/antenna'),
    auth: PasswordAuth(d.password),
  );
  return m;
}

/// Frame 44: a TUI's attributes in the agent terminal, written with the sequences xterm 4.0.0 misreads
/// (lib/state/terminal_sgr.dart): modifyOtherKeys as Claude Code writes it in iTerm2, `22` after bold, the underline
/// styles with colons, the underline color, colors with colons. Only the words "underlined" may be underlined; bold,
/// dim, italic and inverse end where the line says.
String get _attrsSample {
  const e = '\x1b[';
  String fg(int r, int g, int b, {bool colons = false}) => colons ? '${e}38:2::$r:$g:${b}m' : '${e}38;2;$r;$g;${b}m';
  final orange = fg(215, 119, 87);
  final grey = fg(153, 153, 153);
  const width = 64;
  final head = '╭─── ${e}1mClaude Code${e}22m ${grey}v2.1.233$orange ';
  final inner = ' Only the words "underlined" are underlined.'.padRight(width - 2);
  String cells(int from, int to, String cell) => [for (var c = from; c <= to; c++) '$e${c}m$cell'].join();
  final palette = [
    for (var i = 0; i < 24; i++) '${e}38;5;${16 + i * 9}m█',
    for (var i = 0; i < 24; i++) '${e}38:5:${232 + i}m█',
  ].join();
  final gradient = [for (var i = 0; i < 48; i++) '${fg(255 - i * 5, 60 + i * 3, i * 5, colons: i.isOdd)}█'].join();
  return [
    // Claude Code in iTerm2 starts with the kitty keyboard and modifyOtherKeys sequences.
    '$e<u$e>1u$e>4;2m$e?2026h$orange$head${'─' * (width - 27)}╮${e}39m',
    '$orange│${e}39m$inner$orange│${e}39m',
    '$orange╰${'─' * (width - 2)}╯${e}39m',
    ' bold:              ${e}1mbold${e}22m, then normal',
    ' dim:               ${e}2mdim${e}22m, then normal',
    ' italic:            ${e}3mitalic${e}23m, then normal',
    ' underline:         ${e}4munderlined${e}24m, then not',
    ' curly underline:   ${e}4:3munderlined${e}4:0m, then not',
    ' colored underline: ${e}4:3;58:2::255:80:80munderlined${e}59;24m, ${e}58;5;196mthen not${e}59m',
    ' inverse:           ${e}7minverse${e}27m, then normal',
    ' 16 colors:         ${cells(30, 37, '██')} ${cells(90, 97, '██')}${e}39m',
    ' backgrounds:       ${cells(40, 47, '  ')}${e}49m ${cells(100, 107, '  ')}${e}49m',
    ' 256 colors:        $palette${e}39m',
    ' truecolor:         $gradient${e}39m',
    // Claude Code resets modifyOtherKeys when it leaves the alternate screen: the next line stays plain.
    '$e>4m ${e}2mafter modifyOtherKeys reset:${e}22m normal',
    '',
    '$e?2026l$e>4m${e}1m>${e}22m ${e}7m ${e}27m',
  ].join('\r\n');
}

Future<void> _codeFrame(WidgetTester t, AppModel m, FakeAgentComputer pc, Appearance look) async {
  await _frame(t, XApp(model: m, appearance: look));
  pc.last.emit(_claudeSession);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void _defineCodeScenarios() {
  _s('34_code_mode', (t) async {
    const name = '34_code_mode';
    final pc = _mac();
    final m = await _codeWindow(pc);
    await _codeFrame(t, m, pc, Appearance(ui: InterfaceMode.code));
    await _snap(t, name);
    for (final r in m.runs) {
      r.kill();
    }
  });

  _s('34_code_mode_dark', (t) async {
    const name = '34_code_mode_dark';
    final pc = _mac();
    final m = await _codeWindow(pc);
    await _codeFrame(t, m, pc, Appearance(initial: ThemeChoice.dark, ui: InterfaceMode.code));
    await _snap(t, name);
    for (final r in m.runs) {
      r.kill();
    }
  });

  _s('35_start_agent', (t) async {
    const name = '35_start_agent';
    final d = _demo()..agentList = _codeAgents();
    final m = await _codeModel(d, _mac());
    await _frame(t, XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    await t.tap(find.byKey(const Key('code-start-empty')));
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('owner-password')), 'correct horse battery');
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('36_agents_detected', (t) async {
    const name = '36_agents_detected';
    final d = _demo()..agentList = _codeAgents();
    final m = await _codeModel(d, _mac());
    await _frame(
      t,
      XApp(model: m, appearance: Appearance(ui: InterfaceMode.code, rolePreset: RolePreset.assistant)),
    );
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  // Frame 51: the quick replies under the running agent's terminal, the note on the last wake (a message from Jordan's
  // side addressed to the agent, typed as the built-in line once Claude Code sat idle), the tab's menu with the switch.
  _s('51_code_quick_replies', (t) async {
    const name = '51_code_quick_replies';
    final pc = _mac();
    final m = await _codeWindow(pc);
    await _frame(t, XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    final rule = '─' * 40;
    // Claude Code's idle prompt, the cursor right after `❯ ` (the screen check, code_screen.dart).
    pc.last.emit('\x1b[2J\x1b[H$rule\r\n❯ \r\n$rule\r\n  ? for shortcuts\x1b[2;3H');
    await t.pump();
    m.handleEvent(MessageEvent(
      contact: jordanName,
      linkId: jordan.linkId,
      message: msg(990, false, 'The preview.4 build installs fine. Add the release notes?', fixedNow,
          to: 'agent', toAgent: 'claude-backend'),
    ));
    await t.pump(const Duration(seconds: 5));
    await t.pump(AgentRun.enterDelay);
    pc.last.emit('\x1b[2J\x1b[H$_claudeWoken');
    await t.pump();
    await t.tap(find.byKey(const Key('code-menu')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
    m.disposeCodeWake();
    for (final r in m.runs) {
      r.kill();
    }
  });

  // "Stop agent and its processes" (CONTROL §33): the confirmation from the tab's menu.
  _s('96_agent_stop', (t) async {
    const name = '96_agent_stop';
    final pc = _mac();
    final m = await _codeWindow(pc);
    await _frame(t, XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    pc.last.emit(_claudeSession);
    await t.pump();
    await t.tap(find.byKey(const Key('code-menu')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('code-stop-all')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
    m.disposeCodeWake();
    for (final r in m.runs) {
      r.kill();
    }
  });

  _s('44_code_terminal_attrs', (t) async {
    const name = '44_code_terminal_attrs';
    final pc = _mac();
    final d = _demo()..agentList = _codeAgents();
    final m = await _codeModel(d, pc);
    await m.startAgent(
      const AgentRunSpec(agent: 'claude-backend', cli: AgentCli.claude, workDir: '/Users/owner/projects/antenna'),
      auth: PasswordAuth(d.password),
    );
    await _frame(t, XApp(model: m, appearance: Appearance(ui: InterfaceMode.code)));
    pc.last.emit(_attrsSample);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
    for (final r in m.runs) {
      r.kill();
    }
  });
}
