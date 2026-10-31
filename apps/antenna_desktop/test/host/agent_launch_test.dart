// SPDX-License-Identifier: AGPL-3.0-only
// Code mode launches: what the window starts in the terminal for Claude Code, Codex and an own command. The token is
// only in the environment, never in an argument; the wrapper forks the agent (it must not be a session leader, D-28),
// closes inherited descriptors and reports the exit code.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/program_locator.dart';
import 'package:antenna_desktop/host/pty.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'xat_TESTTOKEN0123456789abcdefghijklmnopqrstu';
const _cli = '/Applications/Antenna.app/Contents/Helpers/antenna';
const _env = {'HOME': '/Users/alex', 'PATH': '/usr/bin:/bin', 'LANG': 'ru_RU.UTF-8', 'SECRET_OF_WINDOW': 'x'};

AgentLaunch _launch(AgentCli cli, String program) => buildAgentLaunch(
      cli: cli,
      program: program,
      token: _token,
      antennaPath: _cli,
      socket: '/Users/alex/.local/share/antenna/antennad.sock',
      workDir: '/Users/alex/projects/app',
      shell: '/bin/bash',
      env: _env,
      searchDirs: ProgramLocator(windows: false, env: _env, readFile: (_) => null).searchDirs,
    );

void main() {
  test('Claude Code: MCP config and hooks for this process only; the token only in the environment', () {
    final l = _launch(AgentCli.claude, '/Users/alex/.local/bin/claude');
    expect(l.executable, '/bin/bash');
    expect(l.arguments.take(5), ['-c', agentWrapperScript, agentWrapperName, '/Users/alex/projects/app', '/Users/alex/.local/bin/claude']);
    expect(l.command.first, '/Users/alex/.local/bin/claude');
    final i = l.command.indexOf('--mcp-config');
    final mcp = json.decode(l.command[i + 1]) as Map<String, Object?>;
    expect(mcp, {
      'mcpServers': {
        'antenna': {'type': 'stdio', 'command': _cli, 'args': ['mcp']},
      },
    });
    expect(l.command, contains('--strict-mcp-config'));
    final settings = json.decode(l.command[l.command.indexOf('--settings') + 1]) as Map<String, Object?>;
    final pre = ((settings['hooks']! as Map)['PreToolUse']! as List).single as Map;
    expect(((pre['hooks']! as List).single as Map)['command'], "'$_cli' hook claude-code");
    // No secret anywhere in the arguments (visible to every user in `ps`), only in the environment.
    expect(l.arguments.join(' '), isNot(contains(_token)));
    expect(l.arguments.join(' '), isNot(contains('xat_')));
    expect(l.environment['ANTENNA_AGENT_TOKEN'], _token);
    expect(l.environment['ANTENNA_SOCKET'], '/Users/alex/.local/share/antenna/antennad.sock');
    expect(l.toString(), isNot(contains(_token)));
    // A UTF-8 terminal in the window's language; the program's folder first in PATH (an npm CLI needs its node).
    expect(l.environment['LANG'], 'ru_RU.UTF-8');
    expect(l.environment['TERM'], 'xterm-256color');
    expect(l.environment['PATH']!.split(':').first, '/Users/alex/.local/bin');
    expect(l.environment.containsKey('SECRET_OF_WINDOW'), isFalse, reason: 'only additions, not a copy of the window');
  });

  test('Codex: the MCP server from -c overrides; the token is forwarded by name, a config token is dropped', () {
    final l = _launch(AgentCli.codex, '/opt/homebrew/bin/codex');
    expect(l.command, [
      '/opt/homebrew/bin/codex',
      '-c',
      'mcp_servers.antenna.command="$_cli"',
      '-c',
      'mcp_servers.antenna.args=["mcp"]',
      '-c',
      'mcp_servers.antenna.env={}',
      '-c',
      'mcp_servers.antenna.env_vars=["ANTENNA_AGENT_TOKEN", "ANTENNA_SOCKET"]',
    ]);
    expect(l.arguments.join(' '), isNot(contains('xat_')));
  });

  test('own command: parsed like a shell without running one; empty or unclosed quotes are refused', () {
    final l = _launch(AgentCli.custom, 'aider --model "sonnet 4" --yes');
    expect(l.command, ['aider', '--model', 'sonnet 4', '--yes']);
    expect(l.environment['PATH']!.split(':').first, '/usr/bin', reason: 'no program folder for a bare name');
    for (final bad in ['', '   ', 'aider "unclosed']) {
      expect(() => _launch(AgentCli.custom, bad),
          throwsA(isA<AgentLaunchException>().having((e) => e.reason, 'reason', AgentLaunchFailure.badCommand)));
    }
  });

  test('the wrapper forks the agent (never exec), closes descriptors, reports the exit code', () {
    expect(agentWrapperScript, isNot(contains('exec "\$@"')));
    expect(agentWrapperScript, contains('"\$@"\ne=\$?'));
    expect(agentWrapperScript, contains('/dev/fd/*'));
    expect(agentWrapperScript, contains('\\033]$agentExitOsc;%d\\007'));
  });

  test('the wrapper under bash: runs in the folder, closes fds above 2 (two-digit too), keeps the exit code',
      () async {
    final dir = Directory.systemTemp.createTempSync('antenna-wrap-');
    addTearDown(() => dir.deleteSync(recursive: true));
    // Extra descriptors 7 and 12 are open in the caller; the agent must see only 0, 1, 2.
    final r = await Process.run('/bin/bash', [
      '-c',
      r'exec 7</dev/null 12</dev/null; exec "$@"',
      'outer',
      '/bin/bash',
      '-c',
      agentWrapperScript,
      agentWrapperName,
      dir.path,
      '/bin/bash',
      '-c',
      // List the agent's own numeric descriptors. On Linux /proc/$$/fd shows the shell's; on macOS there is no /proc,
      // so /dev/fd is used — but it reports the *listing process's* descriptors, and reading the directory opens one
      // or two directory descriptors of its own (what made `ls /dev/fd` report a spurious fd 4). Skipping entries that
      // are directories drops those artifacts on both platforms while still catching a leaked /dev/null-style fd.
      r'pwd -P; for d in /proc/$$/fd /dev/fd; do [ -d "$d" ] || continue; for f in "$d"/*; do n=${f##*/}; case $n in ""|*[!0-9]*) continue ;; esac; [ -d "$f" ] && continue; echo "$n"; done; break; done; exit 7',
    ]);
    final out = '${r.stdout}';
    expect(r.exitCode, 7);
    expect(out, contains(dir.resolveSymbolicLinksSync()));
    final fds = out.split('\n').skip(1).where((x) => RegExp(r'^\d+$').hasMatch(x.trim())).map((x) => x.trim()).toSet();
    expect(fds.difference({'0', '1', '2', '3'}), isEmpty, reason: 'inherited: $fds');
    expect(fds, isNot(contains('7')));
    expect(fds, isNot(contains('12')));
    expect(out, contains('\x1b]$agentExitOsc;7\x07'));
    // A missing folder: the wrapper refuses with 126 instead of running the agent elsewhere.
    final missing = await Process.run('/bin/bash',
        ['-c', agentWrapperScript, agentWrapperName, '${dir.path}/nope', '/bin/echo', 'ran']);
    expect(missing.exitCode, 126);
    expect('${missing.stdout}', isNot(contains('ran')));
  }, skip: Platform.isWindows);

  // The window may have been started from another agent's terminal: its session markers must not reach a new agent
  // (Claude Code then thinks it is a child session: no transcript, no resume).
  const fromAgentSession = {
    'HOME': '/Users/alex',
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    'LANG': 'ru_RU.UTF-8',
    'LC_ALL': 'ru_RU.UTF-8',
    'SSH_AUTH_SOCK': '/private/tmp/com.apple.launchd.x/Listeners',
    'ANTHROPIC_API_KEY': 'sk-ant-users-own',
    'CLAUDECODE': '1',
    'CLAUDE_CODE_CHILD_SESSION': '1',
    'CLAUDE_CODE_ENTRYPOINT': 'cli',
    'CLAUDE_CODE_SSE_PORT': '41234',
    'CODEX_THREAD_ID': 'x',
    'CODEX_SANDBOX': 'seatbelt',
    'CODEX_HOME': '/Users/alex/.config/codex',
    'GEMINI_CLI': '1',
    'ANTENNA_AGENT_TOKEN': 'xat_OLDTOKENOFANOTHERAGENT',
    'ANTENNA_AGENT_TOKEN_FILE': '/Users/alex/.local/share/antenna/agents/other.token',
    'X_AGENT_TOKEN': 'xat_PREVIEW',
    'MCP_SESSION_ID': 'abc',
    'TERM_PROGRAM': 'vscode',
    'BASH_ENV': '/Users/alex/.bash_env',
  };

  test('clean environment: session markers and other tokens are removed, the user\'s context stays', () {
    final dirs = ProgramLocator(windows: false, env: fromAgentSession, readFile: (_) => null).searchDirs;
    final l = buildAgentLaunch(
      cli: AgentCli.claude,
      program: '/Users/alex/.local/bin/claude',
      token: _token,
      antennaPath: _cli,
      socket: '/Users/alex/.local/share/antenna/antennad.sock',
      workDir: '/Users/alex/projects/app',
      shell: '/bin/bash',
      env: fromAgentSession,
      searchDirs: dirs,
    );
    final unset = l.environment[agentEnvUnsetVar]!.split(' ').toSet();
    expect(unset, containsAll(['CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT',
      'CODEX_THREAD_ID', 'CODEX_SANDBOX', 'GEMINI_CLI', 'ANTENNA_AGENT_TOKEN_FILE', 'X_AGENT_TOKEN', 'MCP_SESSION_ID',
      'TERM_PROGRAM', 'BASH_ENV', 'ENV']));
    expect(unset.intersection({'HOME', 'LC_ALL', 'SSH_AUTH_SOCK', 'ANTHROPIC_API_KEY', 'PATH', 'LANG', 'ANTENNA_AGENT_TOKEN',
          'CODEX_HOME'}),
        isEmpty, reason: 'kept, or set by the launch itself');
    expect(l.environment['ANTENNA_AGENT_TOKEN'], _token, reason: 'this agent\'s token, not the inherited one');
    expect(l.environment['BASH_ENV'], '', reason: 'the wrapper bash runs no startup file');
  });

  test('clean environment under a real bash: what the agent process actually gets', () async {
    final dir = Directory.systemTemp.createTempSync('antenna-env-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final l = buildAgentLaunch(
      cli: AgentCli.custom,
      program: '/usr/bin/env',
      token: _token,
      antennaPath: _cli,
      socket: '${dir.path}/antennad.sock',
      workDir: dir.path,
      shell: '/bin/bash',
      env: fromAgentSession,
      searchDirs: ProgramLocator(windows: false, env: fromAgentSession, readFile: (_) => null).searchDirs,
    );
    // flutter_pty's child keeps the window's environment and adds the launch's (putenv); the same here.
    final r = await Process.run(l.executable, l.arguments,
        environment: {...fromAgentSession, ...l.environment}, includeParentEnvironment: false);
    final env = {
      for (final line in '${r.stdout}'.split('\n'))
        if (line.contains('=')) line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
    };
    for (final marker in ['CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_ENTRYPOINT', 'CODEX_THREAD_ID',
      'GEMINI_CLI', 'X_AGENT_TOKEN', 'ANTENNA_AGENT_TOKEN_FILE', 'MCP_SESSION_ID', 'TERM_PROGRAM', 'BASH_ENV', 'ENV',
      agentEnvUnsetVar]) {
      expect(env.containsKey(marker), isFalse, reason: marker);
    }
    expect(env['ANTENNA_AGENT_TOKEN'], _token);
    expect(env['HOME'], '/Users/alex');
    expect(env['LANG'], 'ru_RU.UTF-8');
    expect(env['LC_ALL'], 'ru_RU.UTF-8');
    expect(env['SSH_AUTH_SOCK'], fromAgentSession['SSH_AUTH_SOCK']);
    expect(env['PATH'], l.environment['PATH']);
    expect(env['TERM'], 'xterm-256color');
  }, skip: Platform.isWindows || !File('/bin/bash').existsSync());

  test('the PTY environment also removes what the real process environment has beyond the launch\'s', () {
    final l = buildAgentLaunch(
      cli: AgentCli.claude,
      program: '/Users/alex/.local/bin/claude',
      token: _token,
      antennaPath: _cli,
      socket: '/s.sock',
      workDir: '/w',
      shell: '/bin/bash',
      env: const {'HOME': '/Users/alex', 'PATH': '/usr/bin'},
      searchDirs: const ['/usr/bin'],
    );
    final env = agentPtyEnvironment(l.environment, {...fromAgentSession, 'CLAUDE_CODE_NEW_MARKER': '1'});
    final unset = env[agentEnvUnsetVar]!.split(' ');
    expect(unset, containsAll(['CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CODEX_THREAD_ID', 'CLAUDE_CODE_NEW_MARKER',
      'BASH_ENV', 'ENV']));
    expect(unset, isNot(contains('HOME')));
    expect(unset, isNot(contains('ANTENNA_AGENT_TOKEN')), reason: 'set by the launch');
    expect(unset, isNot(contains(agentEnvUnsetVar)));
    expect(env['ANTENNA_AGENT_TOKEN'], _token);
    expect(agentPtyEnvironment(const {'A': 'b'}, fromAgentSession), {'A': 'b'}, reason: 'not an agent launch');
  });

  test('the agent PATH: the login shell\'s (nothing else from it), or the standard tool folders', () async {
    final login = ProgramLocator(
      windows: false,
      env: fromAgentSession,
      isExecutable: {'/bin/zsh'}.contains,
      readFile: (_) => null,
      // A profile that prints its environment, markers included: only the marked PATH line is read.
      loginShell: (_, _, _) async => 'CLAUDECODE=1\nCODEX_THREAD_ID=y\n'
          '__ANTENNA_PATH__/Users/alex/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin\n__ANTENNA_NPM__\n',
    );
    await login.loadLoginShell();
    final path = agentPath(login.searchDirs, programDir: '/Users/alex/.local/bin').split(':');
    expect(path.take(3), ['/Users/alex/.local/bin', '/Users/alex/.cargo/bin', '/opt/homebrew/bin']);
    expect(path.join(':'), isNot(contains('CLAUDECODE')));
    // The login shell failed or timed out: launchd's PATH plus the usual tool folders.
    final failed = ProgramLocator(
        windows: false,
        env: fromAgentSession, isExecutable: {'/bin/zsh'}.contains, readFile: (_) => null, loginShell: (_, _, _) async => null);
    await failed.loadLoginShell();
    expect(agentPath(failed.searchDirs).split(':'), containsAll([
      '/Users/alex/.cargo/bin', '/Users/alex/.local/bin', '/Users/alex/.npm-global/bin', '/opt/homebrew/bin',
      '/opt/homebrew/sbin', '/usr/local/bin', '/usr/bin', '/bin',
    ]));
  });

  test('the shell prefers bash; the agent PATH starts with the program folder, then the searched folders', () {
    // Finding the CLI itself: test/host/program_locator_test.dart.
    expect(findAgentShell(exists: {'/bin/zsh', '/bin/bash'}.contains), '/bin/bash');
    expect(findAgentShell(exists: {'/bin/sh'}.contains), '/bin/sh');
    expect(findAgentShell(exists: (_) => false), isNull);
    final dirs = ProgramLocator(
      windows: false,
      env: const {'HOME': '/home/o', 'PATH': '/usr/bin:/bin'},
      readFile: (_) => null,
    ).searchDirs;
    final path = agentPath(dirs, programDir: '/home/o/.nvm/v22/bin').split(':');
    expect(path.first, '/home/o/.nvm/v22/bin');
    expect(path, containsAllInOrder(['/usr/bin', '/bin', '/home/o/.local/bin', '/opt/homebrew/bin']));
    expect(path.toSet().length, path.length, reason: 'no duplicates');
  });

  // D-103: an agent restored after an update. The token file's path in the environment, never a token; the CLI's own
  // session resumed by its ID (never `--continue`); Codex's notify program records the thread ID.
  group('a restored agent', () {
    const file = '/Users/alex/Library/Application Support/Antenna/agents/claude-backend.token';
    const id = '5f0c2a9e-7d41-4b8e-9a63-2c1d0e8f4b17';
    AgentLaunch restored(AgentCli cli, String program, {String? resume = id, List<String>? notify}) => buildAgentLaunch(
          cli: cli,
          program: program,
          tokenFile: file,
          antennaPath: _cli,
          socket: '/Users/alex/.local/share/antenna/antennad.sock',
          workDir: '/Users/alex/projects/app',
          shell: '/bin/bash',
          env: const {..._env, 'ANTENNA_AGENT_TOKEN': 'xat_INHERITED'},
          searchDirs: const ['/usr/bin'],
          resume: resume,
          notify: notify,
        );

    test('Claude Code: --resume <id>, the token file in the environment, no token anywhere', () {
      final l = restored(AgentCli.claude, '/Users/alex/.local/bin/claude');
      expect(l.command.sublist(l.command.length - 2), ['--resume', id]);
      expect(l.command, isNot(contains('--continue')));
      expect(l.environment[tokenFileVar], file);
      expect(l.environment.containsKey('ANTENNA_AGENT_TOKEN'), isFalse);
      expect(l.environment[agentEnvUnsetVar]!.split(' '), contains('ANTENNA_AGENT_TOKEN'),
          reason: 'a token the window itself inherited does not reach the agent (it would win over the file)');
      expect(l.arguments.join(' '), isNot(contains('xat_')));
      expect(l.arguments.join(' '), isNot(contains(file)), reason: 'the path only in the environment');
    });

    test('Codex: the overrides, notify, then `resume <id>`; the token file forwarded by name', () {
      final l = restored(AgentCli.codex, '/opt/homebrew/bin/codex', notify: ['/bin/sh', '/tmp/code/session-1/notify.sh']);
      expect(l.command, [
        '/opt/homebrew/bin/codex',
        '-c',
        'mcp_servers.antenna.command="$_cli"',
        '-c',
        'mcp_servers.antenna.args=["mcp"]',
        '-c',
        'mcp_servers.antenna.env={}',
        '-c',
        'mcp_servers.antenna.env_vars=["$tokenFileVar", "ANTENNA_SOCKET"]',
        '-c',
        'notify=["/bin/sh","/tmp/code/session-1/notify.sh"]',
        'resume',
        id,
      ]);
      expect(l.environment[tokenFileVar], file);
    });

    test('only a session ID that is a UUID; a token or a token file, never both or neither', () {
      for (final bad in ['--continue', '$id --dangerously-skip-permissions', id.toUpperCase(), '']) {
        expect(() => restored(AgentCli.claude, '/usr/bin/claude', resume: bad), throwsA(isA<AgentLaunchException>()),
            reason: bad);
      }
      expect(
          () => buildAgentLaunch(
              cli: AgentCli.claude,
              program: '/usr/bin/claude',
              token: _token,
              tokenFile: file,
              antennaPath: _cli,
              socket: '/s',
              workDir: '/w',
              shell: '/bin/bash',
              env: const {},
              searchDirs: const []),
          throwsArgumentError);
      expect(
          () => buildAgentLaunch(
              cli: AgentCli.claude,
              program: '/usr/bin/claude',
              antennaPath: _cli,
              socket: '/s',
              workDir: '/w',
              shell: '/bin/bash',
              env: const {},
              searchDirs: const []),
          throwsArgumentError);
    });
  });

  // T15: what an agent on Windows gets, which is all it gets (no wrapper removes anything there).
  test('Windows: the agent environment is the allowlist, ours and a Path with Antenna first', () {
    const window = {
      'SYSTEMROOT': r'C:\Windows', // any case
      'windir': r'C:\Windows',
      'USERPROFILE': r'C:\Users\o',
      'APPDATA': r'C:\Users\o\AppData\Roaming',
      'TEMP': r'C:\Users\o\AppData\Local\Temp',
      'Path': r'C:\Windows\System32;C:\evil-first',
      'HTTPS_PROXY': 'http://proxy:8080',
      // The window's own, never the agent's: another session's markers and a token.
      'CLAUDECODE': '1',
      'CLAUDE_CODE_CHILD_SESSION': '1',
      'ANTENNA_AGENT_TOKEN': 'xat_the_windows_own',
      'NoDefaultCurrentDirectoryInExePath': '0',
    };
    final env = windowsAgentEnvironment(
      window,
      {
        'ANTENNA_AGENT_TOKEN': 'xat_agent',
        'ANTENNA_SOCKET': r'\\.\pipe\antenna-x',
        'TERM': 'xterm-256color',
        'PATH': 'no',
      },
      antennaDir: r'C:\Users\o\AppData\Local\Programs\Antenna',
      programDir: r'C:\Program Files\nodejs',
      searchDirs: [r'C:\Windows\System32', r'c:\windows\system32', r'C:\Users\o\.local\bin'],
    );
    expect(env['SYSTEMROOT'], r'C:\Windows');
    expect(env['windir'], r'C:\Windows');
    expect(env['HTTPS_PROXY'], 'http://proxy:8080');
    expect(env['ANTENNA_AGENT_TOKEN'], 'xat_agent', reason: 'the token only from the launch');
    expect(env['ANTENNA_SOCKET'], r'\\.\pipe\antenna-x');
    expect(env[noCurrentDirectoryVar], '1');
    expect(
      env['Path'],
      r'C:\Users\o\AppData\Local\Programs\Antenna;C:\Program Files\nodejs;C:\Windows\System32;C:\Users\o\.local\bin',
      reason: 'Antenna first, no duplicate in another case, the window\'s own Path not kept',
    );
    // One spelling of each name: Windows reads them in any case.
    final upper = env.keys.map((k) => k.toUpperCase()).toList();
    expect(upper.toSet().length, upper.length);
    // Control: the window's variables outside the lists are not passed on.
    for (final k in ['CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION']) {
      expect(env.containsKey(k), isFalse, reason: k);
    }
  });

  // T14: the Windows launch is `antenna agent-run` with the agent's argv and no shell; the hooks run a bare `antenna`.
  group('Windows', () {
    const antenna = r'C:\Users\o\AppData\Local\Programs\Antenna\antenna.exe';
    const antennaDir = r'C:\Users\o\AppData\Local\Programs\Antenna';
    const hooksDir = r'C:\Users\o\AppData\Local\AntennaCache\code\session-1';
    const notify = [antenna, 'hook-signal', '--notify'];
    const window = {'SystemRoot': r'C:\Windows', 'USERPROFILE': r'C:\Users\o', 'Path': r'C:\Windows\System32'};

    AgentLaunch launch(AgentCli cli, List<String> program, {String? hooks = hooksDir}) => buildWindowsAgentLaunch(
          cli: cli,
          program: program,
          token: _token,
          antennaPath: antenna,
          socket: r'\\.\pipe\antenna-o',
          workDir: r'C:\Users\o\projects\app',
          env: window,
          searchDirs: const [r'C:\Windows\System32'],
          stateHooks: hooks == null ? null : claudeStateHooks((e) => '$hookSignalCommand ${e.word}'),
          notify: cli == AgentCli.codex && hooks != null ? notify : null,
          hooksDir: hooks,
        );

    test('Claude Code: agent-run starts claude.exe; the hooks run a bare antenna; the token only in the spec', () {
      final l = launch(AgentCli.claude, [r'C:\Users\o\.local\bin\claude.exe']);
      expect(l.executable, antenna);
      expect(l.arguments, ['agent-run']);
      expect(l.workingDirectory, r'C:\Users\o\projects\app');
      expect(l.command.first, r'C:\Users\o\.local\bin\claude.exe');
      final mcp = json.decode(l.command[l.command.indexOf('--mcp-config') + 1]) as Map;
      expect(((mcp['mcpServers'] as Map)['antenna'] as Map)['command'], antenna, reason: 'an argv: the full path');
      final hooks = (json.decode(l.command[l.command.indexOf('--settings') + 1]) as Map)['hooks'] as Map;
      List<String> commands(String event) => [
            for (final e in hooks[event] as List)
              for (final h in (e as Map)['hooks'] as List) (h as Map)['command'] as String,
          ];
      expect(commands('PreToolUse'), ['antenna hook claude-code', 'antenna hook-signal tool']);
      expect(commands('PostToolUse'), ['antenna hook claude-code --mark-level 5', 'antenna hook-signal tool-done']);
      expect(commands('Stop'), ['antenna hook-signal stop']);
      expect(l.environment[codeHooksVar], hooksDir, reason: 'hook-signal finds its folder there, for Claude Code too');
      expect(l.environment['ANTENNA_AGENT_TOKEN'], _token);
      expect(l.environment['ANTENNA_SOCKET'], r'\\.\pipe\antenna-o');
      expect(l.environment['Path']!.split(';').take(2), [antennaDir, r'C:\Users\o\.local\bin']);
      expect(l.environment[noCurrentDirectoryVar], '1');
      expect([...l.arguments, ...l.command].join(' '), isNot(contains('xat_')));
      // Control: nothing of the wrapper the other systems use.
      expect(l.environment.containsKey(agentEnvUnsetVar), isFalse);
      expect(l.command.join(' '), isNot(contains('/bin/sh')));
    });

    test('Codex from npm: node.exe runs the package\'s script; notify and the hooks name antenna', () {
      const node = r'C:\Users\o\AppData\Roaming\npm\node.exe';
      const script = r'C:\Users\o\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js';
      final l = launch(AgentCli.codex, [node, script]);
      expect(l.command.take(2), [node, script]);
      expect(l.command, containsAllInOrder(['-c', 'notify=${jsonEncode(notify)}']));
      final overrides = l.command.where((a) => a.startsWith('hooks.')).toList();
      expect(overrides, hasLength(8));
      for (final o in overrides) {
        expect(o, contains('command="antenna hook-signal '), reason: o);
      }
      expect(l.environment[codeHooksVar], hooksDir);
      expect(l.environment['Path']!.split(';').take(2), [antennaDir, r'C:\Users\o\AppData\Roaming\npm'],
          reason: 'node.exe\'s folder after Antenna\'s');
      // Without a hook channel: no hooks, no folder.
      final bare = launch(AgentCli.codex, [node, script], hooks: null);
      expect(bare.command.where((a) => a.startsWith('hooks.') || a.startsWith('notify=')), isEmpty);
      expect(bare.environment.containsKey(codeHooksVar), isFalse);
    });

    test('own command: Windows words (backslashes kept, quotes group), started as they are', () {
      expect(splitWindowsCommand(r'C:\tools\aider.exe --model "sonnet 4" --yes'),
          [r'C:\tools\aider.exe', '--model', 'sonnet 4', '--yes']);
      expect(splitWindowsCommand(r'"C:\Program Files\Agent\agent.exe" a'), [r'C:\Program Files\Agent\agent.exe', 'a']);
      expect(splitWindowsCommand('agent ""'), ['agent', '']);
      expect(splitWindowsCommand('   '), isEmpty);
      expect(splitWindowsCommand('aider "unclosed'), isNull);
      final l = launch(AgentCli.custom, [r'C:\tools\aider.exe', '--yes']);
      expect(l.command, [r'C:\tools\aider.exe', '--yes'], reason: 'no MCP or hook arguments added');
      expect(l.environment.containsKey(codeHooksVar), isFalse);
      expect(l.environment['Path']!.split(';')[1], r'C:\tools');
    });

    test('a token or a token file, not both; an empty program is refused', () {
      expect(
          () => buildWindowsAgentLaunch(
              cli: AgentCli.claude,
              program: const [r'C:\a\claude.exe'],
              token: _token,
              tokenFile: r'C:\t',
              antennaPath: antenna,
              socket: 's',
              workDir: r'C:\w',
              env: const {},
              searchDirs: const []),
          throwsArgumentError);
      expect(() => launch(AgentCli.custom, const []),
          throwsA(isA<AgentLaunchException>().having((e) => e.reason, 'reason', AgentLaunchFailure.badCommand)));
    });
  });
}
