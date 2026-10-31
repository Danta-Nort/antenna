// SPDX-License-Identifier: AGPL-3.0-only
// Code mode: what the window starts in an agent's terminal. Pure Dart (dart:io only for the default file checks).
//
// The agent CLI (Claude Code, Codex or the owner's own command) runs in a pseudo-terminal under a small bash wrapper:
// - the wrapper is the terminal's session leader and forks the agent, so the agent itself is not a session leader and
//   can be the anchor of `antenna mcp` (D-28: a session leader never becomes an anchor; on macOS only a GUI app's main
//   process can, D-P-3);
// - it closes every descriptor the window would otherwise pass on (the PTY plugin forks the window process, and the
//   Flutter engine keeps some descriptors without close-on-exec), then changes to the agent's folder;
// - the agent token goes only into the environment of this process tree; it is never an argument (arguments are
//   visible to every user in `ps`) and never written to disk. The Antenna MCP server comes from the command line of
//   this one process (`--mcp-config` for Claude Code, `-c mcp_servers.…` for Codex), so the user's own CLI settings
//   are not touched.

import 'dart:convert';
import 'dart:io';

import '../host/code_hooks.dart' show codeHooksVar, codexStateHookOverrides, mergeHooks, validSessionId;
import 'agent_snippets.dart' show claudeCodeHooks;
import 'wake.dart' show splitCommand;

/// Which program runs in the agent's terminal.
enum AgentCli {
  claude('claude'),
  codex('codex'),
  custom('');

  const AgentCli(this.binary);

  /// The program's name in PATH (empty for the owner's own command).
  final String binary;

  /// The window gives this CLI automatic lines (D-UI-23, D-UI-25; Codex: PG-21): its hooks or `notify` say when it
  /// waits, and the screen check knows its prompt. An own command gets the quick replies only.
  bool get wakes => this != custom;
}

/// Why a launch cannot be built (the screen says it in words).
enum AgentLaunchFailure {
  /// No bash (or any POSIX shell) for the wrapper.
  noShell,

  /// The CLI (`claude`, `codex`) was not found.
  noProgram,

  /// Windows: the CLI is there only as an npm `.cmd` script, with no program behind it to start without cmd.exe
  /// (`ShimOnly`, host/program_locator.dart; the detail names the CLI, the window's log says why).
  shimOnly,

  /// The working folder does not exist.
  noFolder,

  /// The own command is empty or has an unclosed quote.
  badCommand,

  /// The window has no `antenna` CLI to give the agent as its MCP server.
  noCli,

  /// The window has no terminal on this platform (no PTY).
  noTerminal,
}

final class AgentLaunchException implements Exception {
  const AgentLaunchException(this.reason, [this.detail = '']);
  final AgentLaunchFailure reason;
  final String detail;

  @override
  String toString() => 'AgentLaunchException(${reason.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// What the window starts in the pseudo-terminal.
final class AgentLaunch {
  const AgentLaunch({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.workingDirectory,
    required this.command,
  });

  /// The wrapper shell (an absolute path, so the start cannot fail on a PATH lookup inside the forked window); on
  /// Windows the `antenna` CLI, which hosts the run ([agentRunCommand]).
  final String executable;
  final List<String> arguments;

  /// Variables set on top of the window's environment, including the agent token; on Windows the agent's whole
  /// environment ([windowsAgentEnvironment]).
  final Map<String, String> environment;
  final String workingDirectory;

  /// The agent program's own argv as the wrapper runs it (no secrets in it).
  final List<String> command;

  /// Never prints the environment: it holds the token.
  @override
  String toString() => 'AgentLaunch(${command.join(' ')} in $workingDirectory)';
}

/// The wrapper, run as `bash -c <script> antenna-agent <folder> <program> <args…>`. It must not `exec` the agent:
/// the agent would then be the session leader and could not be the anchor (D-28, D-P-3). dash cannot close
/// descriptors above 9 (the subshell test skips them there), so bash is preferred. After the agent ends, the wrapper
/// reports its exit code in a private OSC ([agentExitOsc]) and pauses briefly so the terminal reads the last output:
/// flutter_pty reports the exit on a separate port and closes the output port when it does.
///
/// First it removes the window's variables the agent must not inherit ([agentEnvUnsetVar], see [agentEnvKeep]):
/// flutter_pty's child only adds to the window's environment (`putenv`), it cannot remove anything. `eval` sees only
/// names checked to be shell identifiers, and plain `unset` works the same in bash, zsh and sh.
const agentWrapperScript = r'''eval "unset ANTENNA_UNSET $ANTENNA_UNSET"
cd -- "$1" || { printf 'antenna: cannot open the folder %s\n' "$1" >&2; exit 126; }
shift
for f in /dev/fd/*; do
  n=${f##*/}
  case $n in ''|*[!0-9]*|0|1|2) continue ;; esac
  (eval "exec $n>&-") 2>/dev/null && eval "exec $n>&-" 2>/dev/null
done
"$@"
e=$?
printf '\033]6973;%d\007' "$e"
sleep 0.2 2>/dev/null
exit $e''';

/// The private OSC the wrapper prints with the agent's exit code (`ESC ] 6973 ; <code> BEL`): the window learns the
/// code from the terminal itself, because the process's own exit status can be taken by the Dart VM, which reaps any
/// child (`wait()`) while the window has other child processes (the daemon on Linux).
const agentExitOsc = '6973';

/// The wrapper's name in `ps` (`$0`).
const agentWrapperName = 'antenna-agent';

/// The shell for the wrapper: bash (present on macOS and on Linux desktops), otherwise zsh or sh.
String? findAgentShell({bool Function(String path)? exists}) {
  final isFile = exists ?? (String p) => File(p).existsSync();
  for (final p in const ['/bin/bash', '/usr/bin/bash', '/bin/zsh', '/usr/bin/zsh', '/bin/sh']) {
    if (isFile(p)) return p;
  }
  return null;
}

/// PATH for the agent: the program's own folder (an npm-installed CLI needs its `node` next to it), then the folders
/// the window searches for programs ([ProgramLocator.searchDirs]: its PATH, the login shell's, the install folders),
/// without duplicates.
String agentPath(List<String> searchDirs, {String? programDir}) {
  final seen = <String>{};
  return [
    ?programDir,
    ...searchDirs,
    '/bin',
    '/usr/sbin',
    '/sbin',
  ].where((d) => d.isNotEmpty && seen.add(d)).join(':');
}

/// The Antenna MCP server for Claude Code's `--mcp-config` (one process only). No token here: `antenna mcp` reads
/// `ANTENNA_AGENT_TOKEN` from the environment Claude Code passes on to it.
String claudeMcpConfig(String antennaPath) => jsonEncode({
      'mcpServers': {
        'antenna': {
          'type': 'stdio',
          'command': antennaPath,
          'args': ['mcp'],
        },
      },
    });

/// Codex `-c` overrides for the Antenna MCP server. Codex starts MCP servers with a clean environment, so the token
/// (or, with [tokenFile], the token file's path) and the socket are forwarded by name (`env_vars`); `env = {}` drops a
/// token a user's own config may carry.
List<String> codexMcpOverrides(String antennaPath, {bool tokenFile = false}) => [
      '-c',
      'mcp_servers.antenna.command=${jsonEncode(antennaPath)}',
      '-c',
      'mcp_servers.antenna.args=["mcp"]',
      '-c',
      'mcp_servers.antenna.env={}',
      '-c',
      'mcp_servers.antenna.env_vars=["${tokenFile ? tokenFileVar : 'ANTENNA_AGENT_TOKEN'}", "ANTENNA_SOCKET"]',
    ];

/// The variable that names the agent's token file (D-86): the CLI reads the token from it, so the window never holds
/// the token for such an agent.
const tokenFileVar = 'ANTENNA_AGENT_TOKEN_FILE';

/// The agent's own argv. [program] is the CLI's absolute path, or the owner's command line for [AgentCli.custom].
/// [hooks]: Claude Code asks the daemon before every tool (`antenna hook claude-code`, CONTROL §5), passed with
/// `--settings` for this session only; [stateHooks] join them there (Claude Code reports its state to the window,
/// D-UI-25). Session settings add to the user's and the project's own; neither file is touched. [addDirs]: folders
/// Claude Code may read without asking (`--add-dir`: the agent's screenshot folder). [resume]: the CLI's own session to
/// continue after an update (D-103): `claude --resume <id>`, `codex resume <id>`; never `--continue`, which takes the
/// newest session in the folder, whoever started it. Only a lower-case UUID is accepted. [notify]: Codex's `notify`
/// program for this session (`-c notify=[…]`, the window's fixed script that records the thread ID). [codexHooks]: Codex's
/// state hooks (`-c hooks.…`, the folder in [codeHooksVar]). [tokenFile]: the token comes from the token file's path in
/// the environment (Codex forwards that variable instead). [windows]: the hooks run a bare `antenna`
/// ([buildWindowsAgentLaunch]).
List<String> agentCommand(
  AgentCli cli,
  String program, {
  required String antennaPath,
  bool hooks = true,
  Map<String, List<Map<String, Object?>>>? stateHooks,
  List<String> addDirs = const [],
  String? resume,
  List<String>? notify,
  bool codexHooks = false,
  bool tokenFile = false,
  bool windows = false,
}) {
  if (resume != null && validSessionId(resume) != resume) {
    throw AgentLaunchException(AgentLaunchFailure.badCommand, 'session id');
  }
  return switch (cli) {
    AgentCli.claude => [
        program,
        '--mcp-config',
        claudeMcpConfig(antennaPath),
        '--strict-mcp-config',
        if (hooks || stateHooks != null) ...[
          '--settings',
          jsonEncode(mergeHooks(
              hooks ? claudeCodeHooks(windows ? 'antenna' : antennaPath, quote: !windows) : const {},
              stateHooks ?? const {})),
        ],
        for (final d in addDirs) ...['--add-dir', d],
        if (resume != null) ...['--resume', resume],
      ],
    // The overrides are the root command's options, so they stand before the `resume` subcommand.
    AgentCli.codex => [
        program,
        ...codexMcpOverrides(antennaPath, tokenFile: tokenFile),
        if (notify != null) ...['-c', 'notify=${jsonEncode(notify)}'],
        if (codexHooks) ...codexStateHookOverrides(windows: windows),
        if (resume != null) ...['resume', resume],
      ],
    AgentCli.custom => switch (splitCommand(program)) {
        final List<String> argv when argv.isNotEmpty => argv,
        _ => throw AgentLaunchException(AgentLaunchFailure.badCommand, program),
      },
  };
}

/// The variable that tells the wrapper which of the window's variables to remove (space-separated names).
const agentEnvUnsetVar = 'ANTENNA_UNSET';

/// What an agent keeps from the window's environment: an allowlist, because the window may itself have been started
/// from another agent's session (a terminal of Claude Code, Codex or Gemini CLI), and the markers such sessions set
/// (`CLAUDECODE`, `CLAUDE_CODE_*` such as `CLAUDE_CODE_CHILD_SESSION`, `CODEX_*`, `GEMINI_CLI*`, `MCP_*`, an agent
/// token, `TERM_PROGRAM`) make a new CLI believe it is that session's child: no transcript, no resume. A denylist would
/// miss the next vendor's marker; this list is the user's own context: who and where they are, their locale and
/// display, their SSH agent, proxies and certificates, and the vendor API settings a CLI reads when the user chose to
/// set them (as in their terminal; a window started from the Dock has none), and where a CLI keeps its own settings and
/// sign-in when the user moved them (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`: configuration, not a session marker; without
/// them such a user's CLI would start signed out). PATH, TERM, COLORTERM, LANG, the token and the socket are set by
/// the launch itself.
const agentEnvKeep = {
  'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'TZ', '__CF_USER_TEXT_ENCODING', //
  'SSH_AUTH_SOCK', 'DISPLAY', 'WAYLAND_DISPLAY', 'XAUTHORITY', 'DBUS_SESSION_BUS_ADDRESS', //
  'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', //
  'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'no_proxy', 'all_proxy', //
  'SSL_CERT_FILE', 'SSL_CERT_DIR', 'NODE_EXTRA_CA_CERTS', 'REQUESTS_CA_BUNDLE', //
  'ANTHROPIC_API_KEY', 'ANTHROPIC_BASE_URL', 'OPENAI_API_KEY', 'OPENAI_BASE_URL', 'GEMINI_API_KEY', 'GOOGLE_API_KEY',
  'GOOGLE_CLOUD_PROJECT', 'XAI_API_KEY', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR',
};

bool _keepVar(String name) => agentEnvKeep.contains(name) || name.startsWith('LC_');

/// Windows: what a program needs from the window's environment to run at all (without `SystemRoot` Winsock does not
/// start; without `TEMP`, `APPDATA` and `LOCALAPPDATA` Node and the CLIs have nowhere to write), next to
/// [agentEnvKeep]'s user context. Names as Windows compares them, in any case.
const agentEnvKeepWindows = {
  'SYSTEMROOT', 'WINDIR', 'COMSPEC', 'PATHEXT', 'TEMP', 'TMP', 'SYSTEMDRIVE', //
  'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMDATA', 'PUBLIC', //
  'PROGRAMFILES', 'PROGRAMFILES(X86)', 'PROGRAMW6432', //
  'COMMONPROGRAMFILES', 'COMMONPROGRAMFILES(X86)', 'COMMONPROGRAMW6432', //
  'USERNAME', 'USERDOMAIN', 'COMPUTERNAME', 'OS', 'NUMBER_OF_PROCESSORS', //
  'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION', 'PSMODULEPATH', //
};

/// The variable that keeps cmd from running a program found in the current folder before `Path` (cmd honours it;
/// PowerShell and Git Bash never look there): a repository holding `antenna.cmd` cannot stand in for Antenna's hooks.
const noCurrentDirectoryVar = 'NoDefaultCurrentDirectoryInExePath';

/// Windows: an agent's whole environment, for `antenna agent-run`'s spec, which is exactly what the agent gets (no
/// wrapper removes anything there). From [windowEnv] only what [agentEnvKeepWindows] and [agentEnvKeep] name (in any
/// case, under the window's own spelling); then [launch] (the token or its file, the socket, the hook folder, TERM,
/// COLORTERM); `Path` with [antennaDir] first (the hooks run a bare `antenna`), then [programDir] (an npm install's
/// `node.exe`), then [searchDirs]; and [noCurrentDirectoryVar]. Any spelling of `PATH` in [launch] or the window's own
/// is replaced.
Map<String, String> windowsAgentEnvironment(
  Map<String, String> windowEnv,
  Map<String, String> launch, {
  required String antennaDir,
  String? programDir,
  required List<String> searchDirs,
}) {
  final keep = {...agentEnvKeepWindows, for (final k in agentEnvKeep) k.toUpperCase()};
  final out = <String, String>{
    for (final e in windowEnv.entries)
      if (keep.contains(e.key.toUpperCase()) || e.key.toUpperCase().startsWith('LC_')) e.key: e.value,
  };
  void put(String name, String value) {
    out.removeWhere((k, _) => k.toUpperCase() == name.toUpperCase());
    out[name] = value;
  }

  for (final e in launch.entries) {
    if (e.key.toUpperCase() != 'PATH') put(e.key, e.value);
  }
  final seen = <String>{};
  final path = [antennaDir, ?programDir, ...searchDirs].where((d) => d.isNotEmpty && seen.add(d.toUpperCase()));
  put('Path', path.join(';'));
  put(noCurrentDirectoryVar, '1');
  return out;
}

/// The window's variables the wrapper removes before the agent starts: everything not kept and not set by the launch.
/// Only shell identifiers can be named (others cannot be set from a profile either).
List<String> agentEnvUnset(Map<String, String> windowEnv, Map<String, String> launchEnv) {
  final ident = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  return [
    for (final k in windowEnv.keys)
      if (!_keepVar(k) && !launchEnv.containsKey(k) && ident.hasMatch(k)) k,
  ]..sort();
}

/// The window's UTF-8 locale for the terminal, if it has one (flutter_pty sets `en_US.UTF-8` otherwise).
String _utf8Lang(Map<String, String> env) {
  for (final k in const ['LC_ALL', 'LC_CTYPE', 'LANG']) {
    final v = env[k] ?? '';
    if (v.toUpperCase().replaceAll('-', '').contains('UTF8')) return v;
  }
  return 'en_US.UTF-8';
}

/// Build the launch for one agent. [token] goes only into [AgentLaunch.environment]; with [tokenFile] instead (D-86,
/// an agent restored after an update), only the file's path does, and the CLI reads the token itself. Exactly one of
/// the two. [socket] is the daemon socket the window uses (the agent must talk to the same daemon that issued the
/// token). [searchDirs] become the agent's PATH after its own folder. [resume] and [notify]: [agentCommand].
/// [codexHooksDir]: Codex's state hooks, reporting into this folder ([codeHooksVar]).
AgentLaunch buildAgentLaunch({
  required AgentCli cli,
  required String program,
  String? token,
  String? tokenFile,
  required String antennaPath,
  required String socket,
  required String workDir,
  required String shell,
  required Map<String, String> env,
  required List<String> searchDirs,
  bool hooks = true,
  Map<String, List<Map<String, Object?>>>? stateHooks,
  List<String> addDirs = const [],
  String? resume,
  List<String>? notify,
  String? codexHooksDir,
}) {
  if ((token == null) == (tokenFile == null)) throw ArgumentError('a token or a token file, not both');
  final command = agentCommand(cli, program,
      antennaPath: antennaPath,
      hooks: hooks,
      stateHooks: stateHooks,
      addDirs: addDirs,
      resume: resume,
      notify: notify,
      codexHooks: cli == AgentCli.codex && codexHooksDir != null,
      tokenFile: tokenFile != null);
  final first = command.first;
  final programDir = first.contains('/') ? File(first).parent.path : null;
  final set = {
    'ANTENNA_AGENT_TOKEN': ?token,
    tokenFileVar: ?tokenFile,
    'ANTENNA_SOCKET': socket,
    if (cli == AgentCli.codex && codexHooksDir != null) codeHooksVar: codexHooksDir,
    'PATH': agentPath(searchDirs, programDir: programDir),
    'TERM': 'xterm-256color',
    'COLORTERM': 'truecolor',
    'LANG': _utf8Lang(env),
    // A non-interactive bash runs $BASH_ENV (and sh $ENV) before the wrapper's first line: empty for the wrapper,
    // removed for the agent.
    'BASH_ENV': '',
    'ENV': '',
  };
  return AgentLaunch(
    executable: shell,
    arguments: ['-c', agentWrapperScript, agentWrapperName, workDir, ...command],
    environment: {
      ...set,
      agentEnvUnsetVar: [...agentEnvUnset(env, set), 'BASH_ENV', 'ENV'].join(' '),
    },
    workingDirectory: workDir,
    command: command,
  );
}

/// Windows: the subcommand of `antenna` that hosts a run (crates/antenna-cli/src/agent_run.rs, host/windows_pty.dart).
const agentRunCommand = 'agent-run';

/// Windows: the owner's own command split into words, as a Windows program reads its command line: spaces and tabs
/// separate, double quotes group (a backslash is an ordinary character, so `C:\tools\agent.exe` stays whole); no shell
/// and no expansions. `null` on an unclosed quote.
List<String>? splitWindowsCommand(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  var inWord = false;
  var quoted = false;
  for (final c in s.split('')) {
    if (c == '"') {
      quoted = !quoted;
      inWord = true;
    } else if (!quoted && (c == ' ' || c == '\t' || c == '\n' || c == '\r')) {
      if (inWord) out.add(cur.toString());
      cur.clear();
      inWord = false;
    } else {
      cur.write(c);
      inWord = true;
    }
  }
  if (quoted) return null;
  if (inWord) out.add(cur.toString());
  return out;
}

/// The folder of a Windows path (`null`: none named).
String? _windowsParent(String path) {
  final i = path.lastIndexOf(r'\');
  return i > 0 ? path.substring(0, i) : null;
}

/// Windows (D-134): the launch for one agent. The window starts `antenna agent-run` ([antennaPath]) and sends
/// it the agent's argv, its folder and its whole environment as the run's spec (host/windows_pty.dart); no shell takes
/// part. [program] is how the agent starts, every program a full path: the CLI's `.exe`, or `node.exe` and the script
/// of an npm install; for [AgentCli.custom], the owner's whole argv. The environment is [windowsAgentEnvironment]'s:
/// Antenna's folder first in Path, because the hooks run a bare `antenna` ([agentCommand] with `windows`, and
/// [hooksDir]'s channel), and they find their folder through [codeHooksVar], for Claude Code and Codex alike. The rest
/// as in [buildAgentLaunch].
AgentLaunch buildWindowsAgentLaunch({
  required AgentCli cli,
  required List<String> program,
  String? token,
  String? tokenFile,
  required String antennaPath,
  required String socket,
  required String workDir,
  required Map<String, String> env,
  required List<String> searchDirs,
  bool hooks = true,
  Map<String, List<Map<String, Object?>>>? stateHooks,
  List<String> addDirs = const [],
  String? resume,
  List<String>? notify,
  String? hooksDir,
}) {
  if ((token == null) == (tokenFile == null)) throw ArgumentError('a token or a token file, not both');
  if (program.isEmpty) throw const AgentLaunchException(AgentLaunchFailure.badCommand);
  final command = cli == AgentCli.custom
      ? program
      : [
          // `node.exe` before an npm install's script; the script stands where the CLI's own path would.
          ...program.take(program.length - 1),
          ...agentCommand(cli, program.last,
              antennaPath: antennaPath,
              hooks: hooks,
              stateHooks: stateHooks,
              addDirs: addDirs,
              resume: resume,
              notify: notify,
              codexHooks: cli == AgentCli.codex && hooksDir != null,
              tokenFile: tokenFile != null,
              windows: true),
        ];
  final antennaDir = _windowsParent(antennaPath);
  if (antennaDir == null) throw AgentLaunchException(AgentLaunchFailure.noCli, antennaPath);
  return AgentLaunch(
    executable: antennaPath,
    arguments: const [agentRunCommand],
    environment: windowsAgentEnvironment(
      env,
      {
        'ANTENNA_AGENT_TOKEN': ?token,
        tokenFileVar: ?tokenFile,
        'ANTENNA_SOCKET': socket,
        if (cli != AgentCli.custom && hooksDir != null) codeHooksVar: hooksDir,
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
      },
      antennaDir: antennaDir,
      programDir: _windowsParent(command.first),
      searchDirs: searchDirs,
    ),
    workingDirectory: workDir,
    command: command,
  );
}
