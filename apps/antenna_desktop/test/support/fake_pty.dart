// SPDX-License-Identifier: AGPL-3.0-only
// A pseudo-terminal stand-in for Code mode tests: records what the window starts (program, arguments, environment)
// and lets the test write the agent's output and end the process.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/host/code_hooks.dart';
import 'package:antenna_desktop/host/program_locator.dart';
import 'package:antenna_desktop/host/pty.dart';
import 'package:antenna_desktop/host/screen_permission.dart';
import 'package:antenna_desktop/host/screenshot.dart';
import 'package:antenna_desktop/state/agent_launch.dart';
import 'package:antenna_desktop/state/code_mode.dart';

import 'fake_agent_folder.dart';

class FakePty implements PtyProcess {
  FakePty(this.launch, {required this.pid, required this.rows, required this.columns, this.exitOnHangup = true});

  final AgentLaunch launch;
  @override
  final int pid;
  int rows;
  int columns;

  /// SIGHUP ends the process (like Claude Code); `false`: it ignores SIGHUP and needs SIGKILL.
  final bool exitOnHangup;
  final _out = StreamController<Uint8List>();
  final _exit = Completer<int?>();
  final written = <String>[];
  final signals = <ProcessSignal>[];

  /// The agent prints [text].
  void emit(String text) => _out.add(Uint8List.fromList(utf8.encode(text)));

  /// The process ends with [code] (negative: a signal).
  void end(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_out.close());
  }

  bool get ended => _exit.isCompleted;

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void write(Uint8List data) => written.add(utf8.decode(data));

  @override
  void resize(int rows, int columns) {
    this.rows = rows;
    this.columns = columns;
  }

  @override
  bool signalGroup(ProcessSignal signal) {
    signals.add(signal);
    if (signal == ProcessSignal.sigkill || (signal == ProcessSignal.sighup && exitOnHangup)) end(-signal.signalNumber);
    return true;
  }
}

/// Claude Code's hook channel in tests: the test reports events as Claude Code would, and plays the Stop hook.
class FakeCodeHooks implements CodeHooks {
  void Function(ClaudeHookEvent e)? _on;

  /// The continuation waiting for the Stop hook (`null`: none).
  String? waiting;

  /// Every continuation the window left, in order.
  final offers = <String>[];
  bool closed = false;

  @override
  String command(ClaudeHookEvent e) => "/bin/sh '/fake/hooks/hook.sh' ${e.word}";

  @override
  void listen(void Function(ClaudeHookEvent e) onEvent) => _on = onEvent;

  void Function(String id)? _onId;

  @override
  void onSession(void Function(String id) onId) => _onId = onId;

  @override
  List<String> get notifyArgv => const ['/bin/sh', '/fake/hooks/notify.sh'];

  @override
  String get folder => '/fake/hooks';

  /// Claude Code ran the hook for [e].
  void emit(ClaudeHookEvent e) => _on?.call(e);

  /// The scripts recorded session ID [id] (the real channel reports only valid ones: [validSessionId]).
  void session(String id) {
    final v = validSessionId(id);
    if (v != null) _onId?.call(v);
  }

  /// The turn ends: the Stop hook continues with a waiting line (unless [active], `stop_hook_active`) and returns
  /// what it printed; otherwise it reports `stop`.
  String? stop({bool active = false}) {
    final w = waiting;
    if (!active && w != null) {
      waiting = null;
      emit(ClaudeHookEvent.continued);
      return w;
    }
    emit(ClaudeHookEvent.stop);
    return null;
  }

  @override
  bool offerContinue(String json) {
    waiting = json;
    offers.add(json);
    return true;
  }

  @override
  bool withdrawContinue() {
    final had = waiting != null;
    waiting = null;
    return had;
  }

  @override
  void close() => closed = true;
}

/// A screenshot tool in tests: writes [bytes] (a PNG by default) to the path, or nothing ([cancel]).
class FakeCapture implements ScreenCapture {
  FakeCapture({this.cancel = false, List<int>? bytes}) : bytes = bytes ?? fakePng;
  bool cancel;
  List<int> bytes;
  final paths = <String>[];

  @override
  String get name => 'fake-capture';

  @override
  Future<bool> capture(String path) async {
    paths.add(path);
    if (cancel) return false;
    File(path).writeAsBytesSync(bytes);
    return true;
  }
}

/// macOS Screen Recording as the Runner would answer it (ScreenAccess.swift), with every call counted.
class FakeScreenPermission implements ScreenPermissionHost {
  FakeScreenPermission(this.state, {this.afterRequest});

  /// What the check answers now.
  ScreenPermission state;

  /// What the state becomes when the window asks macOS (the owner answered its question); `null`: unchanged.
  ScreenPermission? afterRequest;
  int checks = 0;
  int requests = 0;

  @override
  Future<ScreenPermission> check() async {
    checks++;
    return state;
  }

  @override
  Future<ScreenPermission> request() async {
    requests++;
    state = afterRequest ?? state;
    return state;
  }
}

/// The smallest PNG signature with a few bytes after it (the window checks the signature and the size).
const fakePng = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52];

/// A computer for Code mode tests: Claude Code and Codex "installed" at fixed paths, bash present, every absolute
/// folder exists except those under `/missing`.
class FakeAgentComputer {
  FakeAgentComputer({
    this.installed = const {'/usr/local/bin/claude', '/opt/homebrew/bin/codex'},
    this.exitOnHangup = true,
    this.macos = false,
    this.windows = false,
    this.env = const {'HOME': '/home/owner', 'PATH': '/usr/local/bin:/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    this.hooks = false,
    this.shots,
    this.capture,
    this.screenPermission,
    this.loginShell,
  });

  /// The user's login shell (its PATH); `null`: none is read, as on a host without one.
  final LoginShellRunner? loginShell;

  /// Claude Code runs report through [FakeCodeHooks] ([hookChannels]); `false`: no hooks (the screen check only).
  final bool hooks;
  final hookChannels = <FakeCodeHooks>[];

  /// Screenshots: a store in a temporary folder and a fake tool (`null`: none on this computer).
  final ScreenshotStore? shots;
  final ScreenCapture? capture;

  /// macOS Screen Recording (`null`: none, as on Linux).
  final ScreenPermissionHost? screenPermission;

  /// The window's environment as the agent host sees it.
  final Map<String, String> env;

  /// Detection follows this OS (apps in `/Applications` on a Mac, binaries on Linux), not the test machine's.
  final bool macos;

  /// Windows, where Code mode is not built yet (`AgentHost.windows`); not the test machine's, so the Code mode tests
  /// run the same on every system.
  final bool windows;

  final Set<String> installed;
  bool exitOnHangup;
  final ptys = <FakePty>[];
  int _pid = 4100;

  /// Folders `prepareOwnFolder` was asked to create, in order (no real disk access in tests).
  final createdFolders = <String>[];

  /// The working folders "Set up this folder" reads and writes (in memory; every folder exists but `/missing…`), and
  /// the git it runs there.
  late final folders = FakeAgentFolder(dirExists: (p) => !p.startsWith('/missing'));
  late final git = FakeFolderGit(folders: folders);

  /// Started launches, in order.
  List<AgentLaunch> get launches => [for (final p in ptys) p.launch];

  FakePty get last => ptys.last;

  late final host = AgentHost(
    startPty: (launch, {required rows, required columns}) {
      final p = FakePty(launch, pid: ++_pid, rows: rows, columns: columns, exitOnHangup: exitOnHangup);
      ptys.add(p);
      return p;
    },
    env: env,
    shell: '/bin/bash',
    macos: macos,
    windows: windows,
    fileExists: installed.contains,
    folderExists: (p) => p.endsWith('.app') ? installed.contains(p) : !p.startsWith('/missing'),
    newHooks: hooks ? () => FakeCodeHooks()..let(hookChannels.add) : null,
    programs: loginShell == null
        ? null
        : ProgramLocator(
            env: env,
            isExecutable: installed.contains,
            readFile: (_) => null,
            listDir: (_) => const [],
            loginShell: loginShell,
            windows: windows,
          ),
    shots: shots,
    findCapture: capture == null ? null : (_) => capture,
    screenPermission: screenPermission ?? const NoScreenPermission(),
    ensureOwnFolder: createdFolders.add,
    folders: folders,
    folderGit: git,
  );
}

extension _Let<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}
