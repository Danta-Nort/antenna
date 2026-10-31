// SPDX-License-Identifier: AGPL-3.0-only
// Code mode: agents run in terminals inside the window (DESIGN "Code mode", DECISIONS D-UI-15).
//
// "Start agent" is one action: the window asks the daemon for the agent's token through the owner flow (`agent_add`
// for a new agent, `agent_token` for an existing one; both need the owner password, the daemon checks it), keeps the
// token in memory only, and starts the agent's CLI in a pseudo-terminal with the token in that process's environment
// (agent_launch.dart). The daemon then recognizes the CLI's process tree as the agent (D-28): `antenna mcp` binds the
// token to the CLI, which is not a session leader thanks to the wrapper.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xterm/core.dart';

import '../host/agent_folder.dart';
import '../host/binaries.dart';
import '../host/code_hooks.dart';
import '../host/program_locator.dart';
import '../host/pty.dart';
import '../host/screen_permission.dart';
import '../host/screenshot.dart';
import '../host/windows_pty.dart';
import '../protocol/x_control.dart';
import 'agent_launch.dart';
import 'ai_apps.dart';
import 'claude_state.dart';
import 'code_wake.dart';
import 'owner_auth.dart';
import 'terminal_mouse.dart';
import 'terminal_sgr.dart';
import 'wake.dart' show splitCommand;

/// What Code mode needs from this computer. `null` in the model means there is no terminal (a test without one).
final class AgentHost {
  /// [fileExists] stands in for the file system in tests (it then also decides which programs are installed, and no
  /// login shell runs); [programs] replaces the locator altogether.
  AgentHost({
    required this.startPty,
    required this.env,
    String? shell,
    bool? macos,
    bool? windows,
    bool Function(String path)? fileExists,
    bool Function(String path)? folderExists,
    ProgramLocator? programs,
    this.newHooks,
    this.shots,
    this.findCapture,
    this.screenPermission = const NoScreenPermission(),
    void Function(String path)? ensureOwnFolder,
    AgentFolderFs? folders,
    AgentFolderGit? folderGit,
  })  : shell = shell ?? findAgentShell(exists: fileExists),
        macos = macos ?? Platform.isMacOS,
        windows = windows ?? Platform.isWindows,
        _fileExists = fileExists,
        _folderExists = folderExists ?? ((p) => Directory(p).existsSync()),
        _ensureOwnFolder = ensureOwnFolder ?? createPrivateFolder,
        folders = folders ?? const DiskAgentFolder(),
        _gitOverride = folderGit,
        programs = programs ??
            ProgramLocator(
              env: env,
              isExecutable: fileExists,
              readFile: fileExists == null ? null : (_) => null,
              listDir: fileExists == null ? null : (_) => const [],
              windows: windows ?? Platform.isWindows,
            );

  /// The real computer: flutter_pty, the window's environment, bash, and the user's login shell for its PATH. On
  /// Windows the terminal is `antenna agent-run` ([WindowsAgentPty]) and the hooks run `antenna hook-signal`: both need
  /// [cli], the `antenna` next to the window (no hooks without it).
  factory AgentHost.system(Map<String, String> env, {String? cli}) {
    final hooksRoot = codeHooksRoot(env);
    final windows = Platform.isWindows;
    return AgentHost(
      startPty: windows ? WindowsAgentPty.start : SystemPty.start,
      env: env,
      programs: ProgramLocator(env: env, loginShell: runLoginShell),
      newHooks: hooksRoot == null || (windows && cli == null)
          ? null
          : () => FileCodeHooks.create(hooksRoot, windowsCli: windows ? cli : null),
      shots: ScreenshotStore.forEnv(env),
      findCapture: (p) => SystemScreenCapture.detect(p, env: env),
      screenPermission: ChannelScreenPermission.forPlatform(),
    );
  }

  final PtyStarter startPty;

  /// The window's environment (PATH, HOME, LANG).
  final Map<String, String> env;

  /// The wrapper shell (bash); `null`: none found.
  final String? shell;
  final bool macos;

  /// Windows: its paths and rules (the home folder, the agent's own folder, the locator) and its start: `antenna
  /// agent-run` with the agent's argv, no shell (D-134). Until that start has been
  /// checked on a Windows computer, the window does not offer Code mode there and says it is coming
  /// ([CodeMixin.codeComing]). AI app detection works.
  final bool windows;
  final bool Function(String path)? _fileExists;
  final bool Function(String path) _folderExists;

  /// Creates an agent's own folder on disk (tests replace this; the real one is [createPrivateFolder]).
  final void Function(String path) _ensureOwnFolder;

  /// A working folder's files, for "Set up this folder" (state/agent_setup.dart).
  final AgentFolderFs folders;
  final AgentFolderGit? _gitOverride;

  /// git for "Set up this folder": the one found where the agent CLIs are (the login shell's PATH included).
  late final AgentFolderGit folderGit = _gitOverride ?? ProcessAgentFolderGit(locate: programs.locate);

  /// Where the agent CLIs are: one locator for AI apps, Start agent and the agent's PATH.
  final ProgramLocator programs;

  /// A new channel for Claude Code's hooks (host/code_hooks.dart); `null`: none here (the screen check only).
  final CodeHooks? Function()? newHooks;

  /// Where screenshots for agents are kept (`null`: no screenshots here).
  final ScreenshotStore? shots;

  /// Looks for the system's screenshot tool ([capture]).
  final ScreenCapture? Function(ProgramLocator programs)? findCapture;
  ScreenCapture? _capture;

  /// The system's screenshot tool (`null`: none found; looked for again until one is, as the login shell's PATH may
  /// add its folder).
  ScreenCapture? get capture => _capture ??= findCapture?.call(programs);

  /// macOS Screen Recording, checked before the tool runs ([NoScreenPermission] where there is none).
  final ScreenPermissionHost screenPermission;

  /// The user's home folder: `HOME`, or on Windows `USERPROFILE` (its name in any case); `/` or empty when unset.
  String get home {
    if (!windows) return env['HOME'] ?? '/';
    for (final e in env.entries) {
      if (e.key.toUpperCase() == 'USERPROFILE') return e.value;
    }
    return '';
  }

  /// The CLI's absolute path (`null`: not installed where we look; always `null` for [AgentCli.custom]).
  String? locate(AgentCli cli) => cli == AgentCli.custom ? null : programs.locate(cli.binary);

  /// Read the login shell's PATH once (in the background); `true` when that found more folders to search.
  Future<bool> loadLoginShell() => programs.loadLoginShell();

  bool folderExists(String path) => (windows ? isWindowsAbsolute(path) : path.startsWith('/')) && _folderExists(path);

  /// [path] is a regular file (not followed through a link): the token file of an agent to restore.
  bool isFile(String path) =>
      _fileExists?.call(path) ?? FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file;

  /// Where [app] is installed here (Agents → AI apps), or `null`.
  String? detect(AiAppDef app) =>
      detectAiApp(app, programs, macos: macos, fileExists: _fileExists, dirExists: (p) => _folderExists(p));

  /// Every catalog app found here, in catalog order, with where it was found.
  List<(AiAppDef, String)> detectApps() => [
        for (final a in aiApps)
          if (detect(a) case final p?) (a, p),
      ];

  /// [agentName]'s own folder: the default working folder once nothing more specific is chosen (TROUBLESHOOTING
  /// "macOS asks Antenna for Documents, Photos, Music…"), so a Code mode agent — and the coding tool's own scan of
  /// its working folder — never lands in the owner's whole home folder by default.
  String ownFolder(String agentName) =>
      windows ? '$home\\Antenna\\agents\\$agentName' : '$home/Antenna/agents/$agentName';

  /// Creates [agentName]'s own folder on disk if it is missing, only this user's (0700; on Windows it takes the
  /// profile's entries: the user, SYSTEM and the Administrators). Called right before a start that will use it, not
  /// when merely showing it as a hint: folders are not created for an agent the owner never actually runs. Never at
  /// the top of a disk: without a home folder below the root (`HOME` unset or `/`; on Windows `USERPROFILE` unset,
  /// relative or a drive's root) nothing is created and the start stops with the reason.
  void prepareOwnFolder(String agentName) {
    final folder = ownFolder(agentName);
    final belowRoot = windows
        ? isWindowsAbsolute(home) && !RegExp(r'^[A-Za-z]:\\?$').hasMatch(home)
        : home.startsWith('/') && home.replaceAll('/', '').isNotEmpty;
    if (!belowRoot) {
      throw FileSystemException('there is no home folder to make the agent\'s own folder in', folder);
    }
    _ensureOwnFolder(folder);
  }
}

/// What to start: the daemon's agent, the CLI and the folder.
final class AgentRunSpec {
  const AgentRunSpec({required this.agent, required this.cli, required this.workDir, this.command = ''});

  /// The agent's name in the daemon (`antenna agent list`).
  final String agent;
  final AgentCli cli;
  final String workDir;

  /// The owner's own command line ([AgentCli.custom]).
  final String command;

  Map<String, Object?> toJson() => {'cli': cli.name, 'dir': workDir, if (command.isNotEmpty) 'cmd': command};

  static AgentRunSpec? fromJson(String agent, Object? j) {
    if (j is! Map) return null;
    final cli = AgentCli.values.where((c) => c.name == j['cli']).firstOrNull;
    final dir = j['dir'];
    if (cli == null || dir is! String) return null;
    final cmd = j['cmd'];
    return AgentRunSpec(agent: agent, cli: cli, workDir: dir, command: cmd is String ? cmd : '');
  }
}

/// A new agent created by "Start agent" (`agent_add`, Q-15: the data label is the owner's explicit choice).
final class NewAgent {
  const NewAgent({required this.name, required this.localLevel, this.links, this.everyone = false});
  final String name;
  final int localLevel;

  /// v6: the agent also reads messages addressed to everyone (CONTROL §20); off by default, as in the daemon.
  final bool everyone;

  /// The agent's contacts (labels); `null` means all.
  final List<String>? links;
}

/// The agent's token is bound to a live process outside this window (`antenna agent list`: `bound_to`): a second
/// copy would get `token_bound` from the daemon, so the window says so before issuing a new token.
final class AgentBusyElsewhere implements Exception {
  const AgentBusyElsewhere(this.agent, this.boundTo);
  final String agent;
  final String boundTo;
}

/// The token for a restart is no longer in memory (the keys were locked): start again with the password.
final class AgentNeedsPassword implements Exception {
  const AgentNeedsPassword();
}

enum AgentRunState { running, stopping, exited, failed }

/// One agent's terminal: a tab in the dock.
class AgentRun extends ChangeNotifier {
  AgentRun(this.id, this.spec, {TerminalTargetPlatform? platform})
      : terminal = Terminal(
          maxLines: scrollbackLines,
          platform: platform ?? (Platform.isMacOS ? TerminalTargetPlatform.macos : TerminalTargetPlatform.linux),
          mouseHandler: agentMouseHandler,
        );

  /// The scrollback the main screen keeps, in lines: bounded, the oldest go first.
  static const scrollbackLines = 10000;

  final int id;
  AgentRunSpec spec;

  /// The terminal's screen and scrollback (xterm); the dock draws it.
  final Terminal terminal;
  AgentRunState state = AgentRunState.running;

  /// How the last process ended: 0…255, or a negative signal number.
  int? exitCode;

  /// The owner pressed "Stop" (or closed the window): the end is not an error.
  bool stoppedByOwner = false;

  /// The owner stopped the agent and its processes from another own computer, by its label (CONTROL §33).
  String? stoppedFrom;

  /// Why the start failed ([AgentLaunchException] or anything the PTY threw).
  Object? error;

  /// The terminal's session leader (the wrapper shell).
  int? pid;

  /// The agent program's argv (no secrets: the token is only in its environment).
  List<String> command = const [];
  DateTime? startedAt;
  DateTime? endedAt;

  PtyProcess? _pty;
  StreamSubscription<String>? _out;
  int _gen = 0;

  /// The exit code the wrapper reported in the terminal ([agentExitOsc]).
  int? _reported;
  bool _disposed = false;

  /// Counts the program's output and the owner's keystrokes: an unchanged count means the terminal stayed silent
  /// (code_wake.dart).
  int activity = 0;

  /// Called on every output or keystroke (code_wake.dart checks again whether the agent waits for input).
  VoidCallback? onActivity;

  /// What Claude Code is doing, from its hooks and the owner's keys (claude_state.dart); reset for every start.
  ClaudeTracker claude = ClaudeTracker();

  /// The channel Claude Code's hooks report through (`null`: not Claude Code, or no channel here).
  CodeHooks? hooks;

  /// Called after each hook event (code_wake.dart).
  void Function(ClaudeHookEvent e)? onHookEvent;

  /// The token file the CLI reads its token from (D-86), when it runs with one instead of a token in its environment
  /// (an agent the window restores after an update, D-103).
  String? tokenFile;

  /// The CLI's own session ID, as its hooks (Claude Code) or its `notify` program (Codex) last recorded it.
  String? sessionId;

  /// The window started this run by itself after an automatic update to this version, in the CLI's last session.
  String? restoredTo;

  /// Before the owner signed in, `agent_watch` was refused as unknown (a daemon older than x-control/7): new messages
  /// could not wake this restored agent.
  bool watchUnavailable = false;

  /// Called with each new session ID (code_restore.dart keeps it in the window settings file).
  void Function(String id)? onSession;

  /// Called when the process ends or fails to start (code_restore.dart: it no longer runs).
  void Function(AgentRun run)? onEnd;

  /// Claude Code's hooks report within this time of its start (SessionStart), or they do not work in it.
  static const hooksGrace = Duration(seconds: 20);

  /// Claude Code (or Codex) has run for [hooksGrace] by [now] without a hook event (or there is no hook channel): the
  /// wake can rely only on the screen check. Codex runs its first hook (SessionStart) only with the first prompt, and
  /// not at all until the owner trusted the hooks.
  bool hooksLate(DateTime now) {
    final started = startedAt;
    return (spec.cli == AgentCli.claude || spec.cli == AgentCli.codex) &&
        !claude.hooksSeen &&
        started != null &&
        now.difference(started) >= hooksGrace;
  }

  /// Enter goes in its own write after this pause: Claude Code reads text and a carriage return that arrive together
  /// as a paste and inserts a line break instead of sending (TROUBLESHOOTING "Code mode").
  static const enterDelay = Duration(milliseconds: 300);

  bool get alive => _pty != null;

  void _active() {
    activity++;
    onActivity?.call();
  }

  /// Type one of the lines built into the app ([AllowedLine]), then Enter; or paste it, without Enter
  /// ([AllowedLine.paste]: a screenshot's path), which only a program that asked for bracketed paste gets. The only
  /// text the window itself writes into a terminal: a contact's message never is (D-UI-23). `false`: nothing written.
  bool typeLine(AllowedLine line) {
    final p = _pty;
    if (p == null) return false;
    if (line.paste) {
      if (!terminal.bracketedPasteMode) return false;
      p.write(Uint8List.fromList(utf8.encode('\x1b[200~${line.text}\x1b[201~')));
      // The prompt holds the attachment now: no automatic Enter until the owner sends it.
      claude.draft = true;
      return true;
    }
    p.write(Uint8List.fromList(utf8.encode(line.text)));
    Timer(enterDelay, () {
      if (identical(_pty, p)) p.write(Uint8List.fromList(const [0x0d]));
    });
    return true;
  }

  /// "Stop" under the terminal, and the urgent interrupt (code_input.dart): Escape for Claude Code and Codex ("esc to
  /// interrupt"), Ctrl+C for an own command. The key goes straight to the program, not through the terminal's own
  /// input, so the tracker is told here: Claude Code reports no hook for an interrupt, and what it does now is unknown
  /// until its next hook or the screen check. Codex reports its Interrupt hook.
  void interrupt() {
    final p = _pty;
    if (p == null) return;
    final esc = spec.cli == AgentCli.claude || spec.cli == AgentCli.codex;
    p.write(Uint8List.fromList([esc ? 0x1b : 0x03]));
    if (spec.cli == AgentCli.claude) claude.onOwnerInput('\x1b');
  }

  /// The screen as the idle checks read it: rows, faint cells and the cursor (code_screen.dart).
  TerminalScreen screen() => TerminalScreen.of(terminal);

  /// The visible rows of the screen, untouched cells as blanks (what a person sees; xterm skips them in its own text).
  List<String> screenRows() => screen().rows;

  /// [exitOsc]: the wrapper reports the exit code in the terminal ([agentExitOsc], Linux and macOS). On Windows only
  /// agent-run's EXIT frame does, so a program's own OSC 6973 is never taken for it.
  void _attach(PtyProcess pty, List<String> argv, DateTime now, {CodeHooks? hooks, bool exitOsc = true}) {
    final gen = ++_gen;
    _pty = pty;
    this.hooks?.close();
    this.hooks = hooks;
    final tracker = claude = ClaudeTracker();
    hooks?.listen((e) {
      if (gen != _gen) return;
      tracker.onHook(e);
      onHookEvent?.call(e);
      _notify();
    });
    hooks?.onSession((id) {
      if (gen != _gen || id == sessionId) return;
      sessionId = id;
      onSession?.call(id);
    });
    pid = pty.pid;
    command = argv;
    state = AgentRunState.running;
    exitCode = null;
    error = null;
    stoppedByOwner = false;
    stoppedFrom = null;
    startedAt = now;
    endedAt = null;
    _reported = null;
    unawaited(_out?.cancel());
    // A stateful decoder: a multi-byte character may be split between two reads. The SGR filter is per process too: it
    // holds an escape sequence split the same way (terminal_sgr.dart: what xterm 4.0.0 misreads).
    final sgr = SgrFilter();
    _out = pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .map(sgr.add)
        .where((s) => s.isNotEmpty)
        .listen((s) {
      terminal.write(s);
      _active();
    });
    terminal.onOutput = (s) {
      // The owner's keys (and the terminal's own answers to the program's queries, which claude_state.dart tells apart).
      tracker.onOwnerInput(s);
      _pty?.write(Uint8List.fromList(utf8.encode(s)));
      _active();
    };
    terminal.onResize = (w, h, _, _) => _pty?.resize(h, w);
    terminal.onPrivateOSC = (code, args) {
      if (exitOsc && code == agentExitOsc && args.isNotEmpty) _reported = int.tryParse(args.first);
    };
    unawaited(pty.exitCode.then((c) {
      if (gen == _gen) _ended(_reported ?? c);
    }));
    _notify();
  }

  void _ended(int? code) {
    _pty = null;
    hooks?.close();
    hooks = null;
    terminal.onOutput = null;
    terminal.onResize = null;
    state = AgentRunState.exited;
    exitCode = code;
    endedAt = DateTime.now();
    onEnd?.call(this);
    _notify();
  }

  void _failed(Object e) {
    _pty = null;
    hooks?.close();
    hooks = null;
    state = AgentRunState.failed;
    error = e;
    exitCode = null;
    endedAt = DateTime.now();
    onEnd?.call(this);
    _notify();
  }

  /// Stop like closing a terminal window: SIGHUP to the terminal's process group, then SIGKILL after 3 s. On Windows
  /// the same two steps are agent-run's Stop and the end of its process, each ending the job with everything in it.
  Future<void> stop() async {
    final p = _pty;
    if (p == null) return;
    stoppedByOwner = true;
    state = AgentRunState.stopping;
    _notify();
    p.signalGroup(ProcessSignal.sighup);
    try {
      await p.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      p.signalGroup(ProcessSignal.sigkill);
      try {
        await p.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        if (identical(_pty, p)) _ended(-9);
      }
    }
  }

  /// The owner stopped the agent and its processes (agent_stop.dart; [from]: the own computer that asked): the tab
  /// says "Stopped", not "exited with code …", when the daemon's sweep ends the process.
  void markStopped({String? from}) {
    stoppedByOwner = true;
    if (from != null) stoppedFrom = from;
    if (_pty != null && state == AgentRunState.running) state = AgentRunState.stopping;
    _notify();
  }

  /// The window is going away without waiting (tests, a disposed model).
  void kill() {
    final p = _pty;
    if (p == null) return;
    stoppedByOwner = true;
    p.signalGroup(ProcessSignal.sigkill);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    hooks?.close();
    hooks = null;
    unawaited(_out?.cancel());
    super.dispose();
  }
}

/// Code mode in the window model: the running agents and their tokens (in memory only).
mixin CodeMixin on ChangeNotifier {
  XDaemon get daemon;

  /// The daemon speaks x-control/6 (`agent_add` takes `everyone`).
  bool get addressing;
  void safeNotify();
  DateTime now();
  AgentHost? get agentHost;
  CoreBinaries? get binaries;
  String get socketPath;
  List<AgentInfo> get agents;
  Future<void> refreshAgents();

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);
  List<WakeRuleInfo> get wakeRules;

  /// The dock's tabs, in the order they were started.
  final List<AgentRun> runs = [];
  AgentRun? activeRun;

  /// The dock's width (dragged by the owner) and whether it is folded to a strip.
  double dockWidth = 560;
  bool dockCollapsed = false;

  /// Tokens issued in this window session (agent → token): in memory only, never shown or written; dropped on lock.
  final Map<String, String> _tokens = {};

  /// Token files the daemon wrote for agents started in this window session (agent → path, D-86): the agents that
  /// are restored after an update run with one (D-103). The window never reads the file; dropped on lock like a token.
  final Map<String, String> _tokenFiles = {};
  int _runIds = 0;

  /// Code mode can start agents here (a terminal and the `antenna` CLI for the MCP server). Never on Windows yet
  /// ([codeComing]).
  bool get codeAvailable => agentHost != null && !agentHost!.windows && binaries?.cli != null;

  /// Code mode is not built for this system yet (Windows, D-134): it is not offered,
  /// the Code interface is turned off, and Settings says it is coming.
  bool get codeComing => agentHost?.windows ?? false;

  /// A start of [agent] with [cli] needs no password: the window holds its token file when the agent is to get one
  /// ([wantsTokenFile]), or its token when not.
  bool hasAgentToken(String agent, {AgentCli cli = AgentCli.claude}) =>
      wantsTokenFile(agent, cli) ? _tokenFiles.containsKey(agent) : _tokens.containsKey(agent);

  /// [agent] started with [cli] gets a token file instead of a token in memory (code_restore.dart: "Restore after an
  /// update" is on and the daemon can update itself). Off here.
  @protected
  bool wantsTokenFile(String agent, AgentCli cli) => false;

  /// [run] started (or failed to start: [codeRunEnded] follows).
  @protected
  void codeRunStarted(AgentRun run) {}

  /// [run]'s process ended (the owner stopped it, it exited, the window closed through its question).
  @protected
  void codeRunEnded(AgentRun run) {}

  /// [run]'s CLI recorded session ID [id].
  @protected
  void codeSessionRecorded(AgentRun run, String id) {}

  AgentRun? runOf(String agent) => runs.where((r) => r.spec.agent == agent).firstOrNull;

  /// The link's wake agent runs only in the daemon's sandbox (the daemon refuses its token, CONTROL §16).
  bool isWakeAgent(String name) => wakeRules.any((r) => r.agent == name);

  /// The agents "Start agent" offers.
  List<AgentInfo> get startableAgents => [for (final a in agents) if (!isWakeAgent(a.name)) a];

  List<AgentRun> get liveRuns => [for (final r in runs) if (r.alive) r];

  /// `bound_to` of [agent] if its token is bound to a live process that is not one of this window's terminals.
  String? busyElsewhere(String agent) {
    final b = agents.where((a) => a.name == agent).firstOrNull?.boundTo;
    if (b == null || b.endsWith('(ended)')) return null;
    return (runOf(agent)?.alive ?? false) ? null : b;
  }

  void selectRun(AgentRun run) {
    activeRun = run;
    dockCollapsed = false;
    safeNotify();
  }

  void setDock({double? width, bool? collapsed}) {
    if (width != null) dockWidth = width;
    if (collapsed != null) dockCollapsed = collapsed;
    safeNotify();
  }

  /// Checks that cost nothing, before a token is issued: the shell, the folder, the CLI. Returns the program and the
  /// shell: on Linux and macOS the CLI's path (or the own command line) and the wrapper shell; on Windows the argv the
  /// run starts with, every program a full path ([_windowsProgram]), and no shell.
  (List<String>, String) _prepare(AgentHost host, AgentRunSpec spec) {
    if (host.windows) {
      if (!host.folderExists(spec.workDir)) throw AgentLaunchException(AgentLaunchFailure.noFolder, spec.workDir);
      return (_windowsProgram(host, spec), '');
    }
    final shell = host.shell;
    if (shell == null) throw const AgentLaunchException(AgentLaunchFailure.noShell);
    if (!host.folderExists(spec.workDir)) throw AgentLaunchException(AgentLaunchFailure.noFolder, spec.workDir);
    final program = switch (spec.cli) {
      AgentCli.custom => (splitCommand(spec.command)?.isNotEmpty ?? false)
          ? spec.command
          : throw AgentLaunchException(AgentLaunchFailure.badCommand, spec.command),
      _ => host.locate(spec.cli) ?? (throw AgentLaunchException(AgentLaunchFailure.noProgram, spec.cli.binary)),
    };
    return ([program], shell);
  }

  /// Windows: how the agent starts, without cmd.exe. Claude Code and Codex: their `.exe`, or `node.exe` with an npm
  /// install's script (ProgramLocator.launchOf); only a `.cmd` is refused with the reason. An own command: its first
  /// word a full path to an `.exe`, or a program's name the locator finds as an `.exe`.
  List<String> _windowsProgram(AgentHost host, AgentRunSpec spec) {
    if (spec.cli == AgentCli.custom) {
      final argv = splitWindowsCommand(spec.command);
      if (argv == null || argv.isEmpty) throw AgentLaunchException(AgentLaunchFailure.badCommand, spec.command);
      final first = argv.first;
      final exe = first.toLowerCase().endsWith('.exe');
      final path = isWindowsAbsolute(first)
          ? (exe && host.isFile(first) ? first : null)
          : host.programs.locate(exe ? first.substring(0, first.length - 4) : first);
      if (path == null) throw AgentLaunchException(AgentLaunchFailure.noProgram, first);
      return [path, ...argv.skip(1)];
    }
    return switch (host.programs.launchOf(spec.cli.binary)) {
      NativeProgram(:final path) => [path],
      NodeProgram(:final node, :final script) => [node, script],
      ShimOnly(:final shim, :final why) => _shimOnly(spec.cli, '$shim: $why'),
      null => throw AgentLaunchException(AgentLaunchFailure.noProgram, spec.cli.binary),
    };
  }

  /// The screen names the CLI; the window's log keeps the shim and the reason.
  static Never _shimOnly(AgentCli cli, String why) {
    debugPrint('antenna/code: ${cli.binary} not started: $why');
    throw AgentLaunchException(AgentLaunchFailure.shimOnly, cli.binary);
  }

  /// "Start agent": issue the token ([create] → `agent_add`; an existing agent → `agent_token`, unless this window
  /// already holds its token) and start the CLI in a new tab. Returns the error or `null`. An agent that already runs
  /// here is only brought to the front.
  /// [auth]: the owner's password or one touch for the token (D-131); none when this window holds the token.
  Future<Object?> startAgent(AgentRunSpec spec, {OwnerAuth? auth, NewAgent? create}) async {
    final owner = auth ?? const PasswordAuth('');
    final host = agentHost;
    if (host == null) return const AgentLaunchException(AgentLaunchFailure.noTerminal);
    final cli = binaries?.cli;
    if (cli == null) return const AgentLaunchException(AgentLaunchFailure.noCli);
    final existing = runOf(spec.agent);
    if (existing != null && existing.alive) {
      selectRun(existing);
      return null;
    }
    // The login shell's PATH (read once per window session): it may be the only place the CLI is found (nvm, a custom
    // npm prefix), and the agent's terminal gets it, so `cargo`, `brew` and the rest work there as in the user's own.
    await host.loadLoginShell();
    final List<String> program;
    final String shell;
    try {
      (program, shell) = _prepare(host, spec);
    } on AgentLaunchException catch (e) {
      return e;
    }
    // An agent restored after an update runs with a token file (D-86, D-103); any other keeps its token in memory.
    final wantFile = wantsTokenFile(spec.agent, spec.cli);
    String? token;
    String? tokenFile;
    try {
      if (create != null) {
        final r = await ownerOp(
            owner,
            (d, pw) => d.agentAdd(create.name,
                localLevel: create.localLevel,
                password: pw,
                links: create.links,
                tokenFile: wantFile,
                everyone: addressing ? create.everyone : null));
        (token, tokenFile) = _issued(r, wantFile);
        unawaited(refreshAgents());
      } else if (_tokenFiles[spec.agent] case final f? when wantFile) {
        tokenFile = f;
      } else if (_tokens[spec.agent] case final t? when !wantFile) {
        token = t;
      } else {
        await refreshAgents();
        final busy = busyElsewhere(spec.agent);
        if (busy != null) return AgentBusyElsewhere(spec.agent, busy);
        (token, tokenFile) =
            _issued(await ownerOp(owner, (d, pw) => d.agentToken(spec.agent, pw, tokenFile: wantFile)), wantFile);
      }
    } on XClientException catch (e) {
      return e;
    }
    // Only what this start used stays: a new token replaced the old one in the daemon (and rewrote its file).
    if (tokenFile != null) {
      _tokenFiles[spec.agent] = tokenFile;
      _tokens.remove(spec.agent);
    } else if (token != null) {
      _tokens[spec.agent] = token;
      _tokenFiles.remove(spec.agent);
    }
    final run = existing ?? AgentRun(++_runIds, spec);
    if (existing == null) {
      runs.add(run);
    } else {
      run.spec = spec;
      _separator(run);
    }
    activeRun = run;
    dockCollapsed = false;
    _launch(run, host, program, shell, cli, token: token, tokenFile: tokenFile);
    safeNotify();
    return null;
  }

  /// The token or the token file from an `agent_added` reply: the file only when it was asked for and written.
  static (String?, String?) _issued(AgentAddedReply r, bool wantFile) =>
      wantFile && r.tokenFile != null ? (null, r.tokenFile) : (r.token, null);

  void _launch(AgentRun run, AgentHost host, List<String> program, String shell, String cli,
      {String? token, String? tokenFile, String? resume}) {
    // Claude Code: its hooks report its state to the window (D-UI-25), and it may read the screenshots the owner gives
    // it from their folder without a permission question. Codex: the same kind of folder holds its hooks (0.160 and
    // later) and the program its `notify` runs, which say when it waits (PG-21) and record the thread ID for a restore
    // (D-103).
    final claude = run.spec.cli == AgentCli.claude;
    final codex = run.spec.cli == AgentCli.codex;
    final hooks = claude || codex ? host.newHooks?.call() : null;
    final shots = claude ? host.shots?.ensureFolder(run.spec.agent) : null;
    run
      ..onEnd = codeRunEnded
      ..tokenFile = tokenFile
      ..sessionId = resume;
    // A start by the owner is not a restore (launchRestored marks its own run after this).
    if (resume == null) {
      run
        ..restoredTo = null
        ..watchUnavailable = false;
    }
    run.onSession = (id) => codeSessionRecorded(run, id);
    try {
      final launch = host.windows
          ? buildWindowsAgentLaunch(
              cli: run.spec.cli,
              program: program,
              token: token,
              tokenFile: tokenFile,
              antennaPath: cli,
              socket: socketPath,
              workDir: run.spec.workDir,
              env: host.env,
              searchDirs: host.programs.searchDirs,
              stateHooks: claude && hooks != null ? claudeStateHooks(hooks.command) : null,
              addDirs: [?shots],
              resume: resume,
              notify: codex ? hooks?.notifyArgv : null,
              hooksDir: hooks?.folder,
            )
          : buildAgentLaunch(
              cli: run.spec.cli,
              program: program.single,
              token: token,
              tokenFile: tokenFile,
              antennaPath: cli,
              socket: socketPath,
              workDir: run.spec.workDir,
              shell: shell,
              env: host.env,
              searchDirs: host.programs.searchDirs,
              stateHooks: claude && hooks != null ? claudeStateHooks(hooks.command) : null,
              addDirs: [?shots],
              resume: resume,
              notify: codex ? hooks?.notifyArgv : null,
              codexHooksDir: codex ? hooks?.folder : null,
            );
      final t = run.terminal;
      run._attach(host.startPty(launch, rows: t.viewHeight, columns: t.viewWidth), launch.command, now(),
          hooks: hooks, exitOsc: !host.windows);
      codeRunStarted(run);
    } on Object catch (e) {
      hooks?.close();
      run._failed(e);
    }
  }

  /// Start [spec] again without the owner after an automatic update (code_restore.dart): the CLI's session [sessionId]
  /// resumed, the token from the daemon's token file [tokenFile]. Returns the run, or the error that stopped it.
  @protected
  Object launchRestored(AgentRunSpec spec, {required String tokenFile, required String sessionId}) {
    final host = agentHost;
    final cli = binaries?.cli;
    if (host == null || cli == null) return const AgentLaunchException(AgentLaunchFailure.noTerminal);
    final List<String> program;
    final String shell;
    try {
      (program, shell) = _prepare(host, spec);
    } on AgentLaunchException catch (e) {
      return e;
    }
    final existing = runOf(spec.agent);
    if (existing != null && existing.alive) return existing;
    final run = existing ?? AgentRun(++_runIds, spec);
    if (existing == null) {
      runs.add(run);
    } else {
      run.spec = spec;
      _separator(run);
    }
    activeRun ??= run;
    _launch(run, host, program, shell, cli, tokenFile: tokenFile, resume: sessionId);
    safeNotify();
    return run;
  }

  void _separator(AgentRun run) => run.terminal.write('\r\n\x1b[2m────────\x1b[0m\r\n');

  /// "Restart": stop the process (if it runs) and start the same CLI again with the token held in memory.
  Future<Object?> restartRun(AgentRun run) async {
    await run.stop();
    final host = agentHost;
    final cli = binaries?.cli;
    if (host == null || cli == null) return const AgentLaunchException(AgentLaunchFailure.noTerminal);
    // The switch as it is now: a restart is a start ("Restore after an update" applies from the next start).
    final wantFile = wantsTokenFile(run.spec.agent, run.spec.cli);
    final tokenFile = wantFile ? _tokenFiles[run.spec.agent] : null;
    final token = wantFile ? null : _tokens[run.spec.agent];
    if (token == null && tokenFile == null) return const AgentNeedsPassword();
    final List<String> program;
    final String shell;
    try {
      (program, shell) = _prepare(host, run.spec);
    } on AgentLaunchException catch (e) {
      return e;
    }
    _separator(run);
    _launch(run, host, program, shell, cli, token: token, tokenFile: tokenFile);
    activeRun = run;
    safeNotify();
    return null;
  }

  Future<void> stopRun(AgentRun run) async {
    await run.stop();
    safeNotify();
  }

  /// Close a tab whose process has ended.
  void closeRun(AgentRun run) {
    if (run.alive) return;
    final i = runs.indexOf(run);
    if (i < 0) return;
    runs.removeAt(i);
    if (identical(activeRun, run)) activeRun = runs.isEmpty ? null : runs[i.clamp(0, runs.length - 1)];
    run.dispose();
    safeNotify();
  }

  /// The window is closing (or the owner chose "Stop all"): no agent is left behind.
  Future<void> stopAllRuns() async {
    await Future.wait([for (final r in liveRuns) r.stop()]);
    safeNotify();
  }

  /// Lock, sign-out, daemon stopped: the tokens and token files leave the window's memory (running agents keep
  /// theirs; a restart then asks for the password again).
  void forgetAgentTokens() {
    _tokens.clear();
    _tokenFiles.clear();
  }

  /// The model is disposed: kill what still runs (a test, or the window torn down without the exit dialog).
  void disposeRuns() {
    for (final r in runs) {
      // Torn down, not stopped by the owner: what the settings file says about the run stays as it was.
      r.onEnd = null;
      r.kill();
      r.dispose();
    }
    runs.clear();
    activeRun = null;
    _tokens.clear();
    _tokenFiles.clear();
  }
}
