// SPDX-License-Identifier: AGPL-3.0-only
// Where command-line programs live for this user: agent CLIs (Claude Code, Codex, Gemini CLI, …) for Agents → AI apps
// and Code mode, and `antenna` / `antennad` outside the app bundle. Pure Dart (dart:io).
//
// A window started from Finder or the Dock gets launchd's environment: PATH is /usr/bin:/bin:/usr/sbin:/sbin, so
// nothing the user installed is in it. The answer to "where is `claude`?" is what the user's terminal would run, so
// the search goes, in order:
//  1. the PATH of the user's login shell, read once per window session in the background (`$SHELL -ilc`, the way
//     editors such as VS Code read it), with `npm prefix -g` for CLIs installed with npm (nvm, volta, a custom
//     prefix);
//  2. the window's own PATH (a window started from a terminal has the terminal's);
//  3. the folders the official installers use: ~/.local/bin (Claude Code's native installer), ~/.claude/local (its
//     older local install), the npm global prefix (~/.npm-global, or `prefix` from ~/.npmrc), ~/.bun/bin,
//     ~/.volta/bin, ~/.cargo/bin, ~/bin, /opt/homebrew/bin, /opt/homebrew/sbin, /usr/local/bin, /usr/bin.
// A candidate counts only when it resolves to a regular file with an execute bit: a symlink to a removed version (an
// updater's leftover) or a stray non-executable file does not stop the search; the next folder may have the program.
// Every place that names or starts a CLI asks this one locator, so the path shown in AI apps is the path Code mode
// starts, and the same list is the PATH of the agents' terminals (only PATH is taken from the login shell).
//
// Windows (D-134, Code mode on Windows): no login shell. The search is the window's `Path` (split on
// `;`, the variable's name in any case), then %USERPROFILE%\.local\bin (Claude Code's native installer) and
// %APPDATA%\npm (npm's global prefix). A program is its `.exe`; a `.cmd` is never run, because it goes through cmd.exe
// (its quoting of our JSON arguments, and its "Terminate batch job?" after Ctrl+C). An npm install is started as
// `node.exe` with the script its package.json names for the program ([launchOf]), and a native `.exe` wins over it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs the login shell with [args] and returns what it printed, or `null` (not started, timed out, no output).
typedef LoginShellRunner = Future<String?> Function(String shell, List<String> args, Duration timeout);

/// The marker lines the login shell prints (anything else it prints, a greeting or a prompt, is ignored).
const _pathMark = '__ANTENNA_PATH__';
const _npmMark = '__ANTENNA_NPM__';

/// What the login shell prints: its PATH, then the npm global prefix (empty without npm). `printenv` rather than
/// `$PATH`, so that fish (where PATH is a list) prints it with colons too.
const loginShellScript = "printf '\\n$_pathMark'; printenv PATH; printf '$_npmMark'; npm prefix -g 2>/dev/null; echo";

/// How long the login shell may take (an interactive zsh with plugins and nvm can take a second or two).
const loginShellTimeout = Duration(seconds: 5);

/// The real login shell: started with stdin closed, killed when it does not finish in time.
Future<String?> runLoginShell(String shell, List<String> args, Duration timeout) async {
  final Process p;
  try {
    p = await Process.start(shell, args);
  } on ProcessException {
    return null;
  }
  unawaited(p.stdin.close());
  unawaited(p.stderr.drain<void>());
  final out = StringBuffer();
  final read = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach(out.write);
  try {
    await p.exitCode.timeout(timeout);
  } on TimeoutException {
    p.kill(ProcessSignal.sigkill);
    return null;
  }
  // A process the profile left in the background may keep the pipe open: do not wait for it.
  await read.timeout(const Duration(milliseconds: 300), onTimeout: () {});
  return out.toString();
}

/// `path` resolves (following symlinks) to a regular file that has an execute bit.
bool isExecutableFile(String path) {
  final st = FileStat.statSync(path);
  return st.type == FileSystemEntityType.file && st.mode & 0x49 != 0;
}

/// Windows: `path` is a regular file (Windows has no execute bit; the locator names `.exe` files itself).
bool isWindowsFile(String path) => FileSystemEntity.typeSync(path) == FileSystemEntityType.file;

/// The names of the folders in [dir] (none when it cannot be listed).
List<String> listFolders(String dir) {
  try {
    return [
      for (final e in Directory(dir).listSync(followLinks: false))
        if (e is Directory) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    ];
  } on FileSystemException {
    return const [];
  }
}

/// How an agent CLI is started ([ProgramLocator.launchOf]).
sealed class ProgramLaunch {
  const ProgramLaunch();
}

/// A program that runs by itself: [path] (on Windows, an `.exe`).
final class NativeProgram extends ProgramLaunch {
  const NativeProgram(this.path);
  final String path;

  @override
  bool operator ==(Object other) => other is NativeProgram && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'NativeProgram($path)';
}

/// Windows: an npm package, started as [node] with [script], the package's own program, never through its `.cmd`.
final class NodeProgram extends ProgramLaunch {
  const NodeProgram({required this.node, required this.script});
  final String node;
  final String script;

  @override
  bool operator ==(Object other) => other is NodeProgram && other.node == node && other.script == script;

  @override
  int get hashCode => Object.hash(node, script);

  @override
  String toString() => 'NodeProgram($node, $script)';
}

/// Windows: only an npm `.cmd` shim was found, with nothing behind it to start without cmd.exe ([why]). Not started:
/// the owner gets the manual steps with the reason.
final class ShimOnly extends ProgramLaunch {
  const ShimOnly(this.shim, this.why);
  final String shim;
  final String why;

  @override
  String toString() => 'ShimOnly($shim: $why)';
}

/// Windows: an absolute path, with a drive (`C:\…`) or a share (`\\host\share\…`).
bool isWindowsAbsolute(String p) => RegExp(r'^[A-Za-z]:\\').hasMatch(p) || p.startsWith(r'\\');

/// The global `prefix` from an `.npmrc` text (`prefix=~/.npm-global`), with `~` and `$HOME` expanded.
String? npmrcPrefix(String text, String home) {
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('#') || line.startsWith(';')) continue;
    final m = RegExp(r'^prefix\s*=\s*(.+)$').firstMatch(line);
    if (m == null) continue;
    var v = m.group(1)!.trim();
    if (v.length >= 2 && (v.startsWith('"') && v.endsWith('"') || v.startsWith("'") && v.endsWith("'"))) {
      v = v.substring(1, v.length - 1);
    }
    if (v == '~' || v.startsWith('~/')) v = '$home${v.substring(1)}';
    v = v.replaceAll(r'${HOME}', home).replaceAll(r'$HOME', home);
    return v.startsWith('/') ? v : null;
  }
  return null;
}

final class ProgramLocator {
  /// [isExecutable] and [readFile] stand in for the file system in tests; [loginShell] is `null` where no login
  /// shell may run (tests, and hosts without one).
  ProgramLocator({
    required this.env,
    bool Function(String path)? isExecutable,
    String? Function(String path)? readFile,
    List<String> Function(String dir)? listDir,
    this.loginShell,
    bool? windows,
  })  : windows = windows ?? Platform.isWindows,
        _isExecutable = isExecutable ?? ((windows ?? Platform.isWindows) ? isWindowsFile : isExecutableFile),
        _readFile = readFile ?? _readSmallFile,
        _listDir = listDir ?? listFolders;

  /// The window's environment (HOME, PATH, SHELL; on Windows USERPROFILE, APPDATA, Path).
  final Map<String, String> env;

  /// Windows paths and rules (the header's last paragraph); not the test machine's.
  final bool windows;
  final bool Function(String path) _isExecutable;
  final String? Function(String path) _readFile;
  final List<String> Function(String dir) _listDir;
  final LoginShellRunner? loginShell;

  /// The PATH folders of the login shell, once read (empty before, and when it could not be read), with the npm
  /// global prefix's `bin`.
  List<String> _loginDirs = const [];

  /// The login shell's PATH alone, as a new terminal gets it ([loginShellPath]).
  List<String> _loginPath = const [];
  bool _loginRead = false;
  Future<bool>? _loading;
  bool _loaded = false;

  String get home => windows ? (_var('USERPROFILE') ?? '') : (env['HOME'] ?? '');

  /// A variable of the window's environment; on Windows its name in any case, as Windows reads it.
  String? _var(String name) {
    if (!windows) return env[name];
    final upper = name.toUpperCase();
    for (final e in env.entries) {
      if (e.key.toUpperCase() == upper) return e.value;
    }
    return null;
  }

  /// The login shell was asked (whatever it answered): [locate] sees everything it will see in this session.
  bool get loginShellLoaded => _loaded;

  /// The PATH a new terminal of this user gets (the login shell's), or `null` when it was not read (yet, or it could
  /// not be): then nobody can say whether a folder is on it.
  List<String>? get loginShellPath => _loginRead ? List.unmodifiable(_loginPath) : null;

  static String? _readSmallFile(String path) {
    try {
      final f = File(path);
      if (!f.existsSync() || f.lengthSync() > 64 * 1024) return null;
      return f.readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  List<String> _windowPath() => windows
      ? [
          for (final p in (_var('PATH') ?? '').split(';'))
            if (isWindowsAbsolute(p.trim())) _trimSlash(p.trim()),
        ]
      : (env['PATH'] ?? '').split(':').where((p) => p.startsWith('/')).toList();

  /// A folder without its trailing backslash (a drive's root keeps it: `C:\`).
  static String _trimSlash(String p) => p.length > 3 && p.endsWith(r'\') ? p.substring(0, p.length - 1) : p;

  /// The install folders of the official installers (step 3 above).
  List<String> get installDirs {
    if (windows) {
      final h = home;
      final appData = _var('APPDATA') ?? '';
      return [
        if (isWindowsAbsolute(h)) '$h\\.local\\bin',
        if (isWindowsAbsolute(appData)) '$appData\\npm',
      ];
    }
    final h = home;
    final npmrc = h.isEmpty ? null : _readFile('$h/.npmrc');
    final npmPrefix = npmrc == null ? null : npmrcPrefix(npmrc, h);
    return [
      if (h.isNotEmpty) ...[
        '$h/.local/bin',
        '$h/.claude/local',
        '$h/.npm-global/bin',
        if (npmPrefix != null) '$npmPrefix/bin',
        '$h/.bun/bin',
        '$h/.volta/bin',
        '$h/.cargo/bin',
        '$h/bin',
      ],
      '/opt/homebrew/bin',
      '/opt/homebrew/sbin',
      '/usr/local/bin',
      '/usr/bin',
    ];
  }

  /// Every folder searched, in order, without duplicates. Once read, the login shell's PATH comes first: it is what the
  /// user's terminal runs (a window started from a terminal has the same PATH anyway; launchd's adds only system
  /// folders). The agents' terminals get this list as their PATH too.
  List<String> get searchDirs {
    final seen = <String>{};
    return [..._loginDirs, ..._windowPath(), ...installDirs].where((d) => seen.add(d)).toList();
  }

  /// The absolute path of the program [name] (`claude`, `codex`, `gemini`, `antenna`), or `null`. On Windows its
  /// `.exe`, never a `.cmd` (an npm install: [launchOf]).
  String? locate(String name) {
    if (windows) {
      if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) return null;
      for (final d in searchDirs) {
        final p = '$d\\$name.exe';
        if (_isExecutable(p)) return p;
      }
      return null;
    }
    if (name.isEmpty || name.contains('/')) return null;
    for (final d in searchDirs) {
      final p = '$d/$name';
      if (_isExecutable(p)) return p;
    }
    return null;
  }

  /// How to start the agent CLI [name]: the program itself ([locate]); on Windows, when there is no `.exe`, an npm
  /// install as `node.exe` and its script ([NodeProgram]), or [ShimOnly] when only a `.cmd` is there. `null`: not
  /// installed where the locator looks.
  ProgramLaunch? launchOf(String name) {
    if (locate(name) case final p?) return NativeProgram(p);
    if (!windows) return null;
    ShimOnly? shim;
    for (final d in searchDirs) {
      final cmd = '$d\\$name.cmd';
      if (!_isExecutable(cmd)) continue;
      final script = _npmScript('$d\\node_modules', name);
      if (script == null) {
        shim ??= ShimOnly(cmd, 'no package in its node_modules names "$name" as its program');
        continue;
      }
      final node = _isExecutable('$d\\node.exe') ? '$d\\node.exe' : locate('node');
      if (node == null) {
        shim ??= ShimOnly(cmd, 'node.exe is not found');
        continue;
      }
      return NodeProgram(node: node, script: script);
    }
    return shim;
  }

  /// The script a package in [modules] names for the program [name] in its package.json (`"bin": {"<name>": …}`, or
  /// `"bin": "…"` in a package called [name]); it must stay inside its package and be there.
  String? _npmScript(String modules, String name) {
    for (final pkg in _packages(modules)) {
      final text = _readFile('$pkg\\package.json');
      if (text == null) continue;
      final Object? json;
      try {
        json = jsonDecode(text);
      } on FormatException {
        continue;
      }
      if (json is! Map) continue;
      final bin = json['bin'];
      final own = json['name'];
      final rel = bin is Map && bin[name] is String
          ? bin[name] as String
          : bin is String && own is String && own.split('/').last == name
              ? bin
              : null;
      if (rel == null || rel.contains(':')) continue;
      final parts = rel.replaceAll(r'\', '/').split('/').where((s) => s.isNotEmpty && s != '.').toList();
      if (parts.isEmpty || parts.contains('..')) continue;
      final script = '$pkg\\${parts.join(r'\')}';
      if (_isExecutable(script)) return script;
    }
    return null;
  }

  /// The package folders in an npm `node_modules` (scoped ones one level down).
  Iterable<String> _packages(String modules) sync* {
    for (final e in _listDir(modules)) {
      if (e.startsWith('.')) continue;
      if (e.startsWith('@')) {
        for (final s in _listDir('$modules\\$e')) {
          yield '$modules\\$e\\$s';
        }
      } else {
        yield '$modules\\$e';
      }
    }
  }

  /// Read the login shell's PATH (once per session; later calls wait for the same answer). `true` when it added
  /// folders the search did not have before, so the caller looks again.
  Future<bool> loadLoginShell() => _loading ??= _load();

  /// Read the login shell's PATH again (after the owner changed their shell profile).
  Future<bool> reloadLoginShell() {
    _loading = null;
    return loadLoginShell();
  }

  Future<bool> _load() async {
    // Windows has no login shell to ask: the window's Path is the user's.
    if (windows) {
      _loaded = true;
      return false;
    }
    final run = loginShell;
    final shell = _shell();
    String? out;
    if (run != null && shell != null) {
      try {
        out = await run(shell, ['-ilc', loginShellScript], loginShellTimeout);
      } on Object {
        out = null;
      }
    }
    _loaded = true;
    if (out == null) return false;
    final before = searchDirs.toSet();
    final dirs = <String>[];
    final path = <String>[];
    var sawPath = false;
    for (final line in const LineSplitter().convert(out)) {
      final i = line.indexOf(_pathMark);
      if (i >= 0) {
        sawPath = true;
        path.addAll(line.substring(i + _pathMark.length).split(':').where((p) => p.startsWith('/')));
        dirs.addAll(path);
      }
      final j = line.indexOf(_npmMark);
      if (j >= 0) {
        final prefix = line.substring(j + _npmMark.length).trim();
        if (prefix.startsWith('/')) dirs.add('$prefix/bin');
      }
    }
    _loginDirs = dirs;
    _loginPath = path;
    _loginRead = sawPath;
    return searchDirs.any((d) => !before.contains(d));
  }

  /// The user's login shell: `$SHELL` when it is an absolute path to a program, else the platform's default.
  String? _shell() {
    final s = env['SHELL'] ?? '';
    if (s.startsWith('/') && _isExecutable(s)) return s;
    for (final p in const ['/bin/zsh', '/bin/bash', '/bin/sh']) {
      if (_isExecutable(p)) return p;
    }
    return null;
  }
}
