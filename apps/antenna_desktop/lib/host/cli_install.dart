// SPDX-License-Identifier: AGPL-3.0-only
// "Install the `antenna` command in the terminal" (DECISIONS D-58). Pure Dart (dart:io).
//
// The command is a symlink to the app's CLI, not a copy: when the app is updated, so is the command.
// - by default `~/.local/bin/antenna`, no administrator rights needed (macOS and Linux);
// - on macOS, by explicit choice, `/usr/local/bin/antenna` via the standard macOS password prompt
//   (`osascript … with administrator privileges`): the window never sees the password, the system itself asks for it.
// Exposing the CLI from the window is safe: it is a client of the same daemon with no extra rights (owner commands
// need the password or a session, agents only get a token).

import 'dart:async';
import 'dart:io';

/// Runs an external command with a time limit (replaced in tests).
typedef CliCommandRunner = Future<ProcessResult> Function(String exe, List<String> args, {required Duration timeout});

/// Run with a limit: if the command does not finish in time, the process is killed (exit code -1) rather than left
/// hanging.
Future<ProcessResult> runWithTimeout(String exe, List<String> args, {required Duration timeout}) async {
  final p = await Process.start(exe, args);
  unawaited(p.stdin.close());
  final out = p.stdout.transform(systemEncoding.decoder).join();
  final err = p.stderr.transform(systemEncoding.decoder).join();
  final code = await p.exitCode.timeout(timeout, onTimeout: () {
    p.kill(ProcessSignal.sigkill);
    return -1;
  });
  return ProcessResult(p.pid, code, await out, await err);
}

/// What is at the command path.
enum CliLinkState {
  /// Nothing.
  absent,

  /// Our link: points to this app's CLI.
  installed,

  /// A symlink to another path (an old app location, another build); it may be replaced.
  otherLink,

  /// A regular file (for example, `antenna` from the `install.sh` archive); never touched.
  otherFile,
}

/// State of the terminal command.
final class CliStatus {
  const CliStatus({required this.link, required this.state, this.currentTarget, this.inPath});

  /// Command path (`~/.local/bin/antenna`).
  final String link;
  final CliLinkState state;

  /// Where the existing link points.
  final String? currentTarget;

  /// Whether the command's directory is in the login shell's PATH; `null` if it could not be determined.
  final bool? inPath;
}

/// Why the command was not installed. The text for the owner is built by the UI, in the window's language
/// (cli_dialog.dart).
enum CliInstallFailure {
  /// The app does not bundle the CLI: [CliInstallException.path] is where we looked.
  notBundled,

  /// The command path in ~/.local/bin is a regular file (for example, from the install.sh archive): never touched.
  userFileExists,

  /// Installing into the system directory is macOS-only.
  macosOnly,

  /// The command path in the system directory is a regular file: never touched.
  systemFileExists,

  /// osascript failed: [CliInstallException.detail] is its stderr (if empty, see the exit code).
  osascript,
}

/// An install error: the reason and raw details (path, stderr); the UI builds the text.
final class CliInstallException implements Exception {
  const CliInstallException(this.reason, {this.path = '', this.detail = '', this.exitCode});
  final CliInstallFailure reason;
  final String path;
  final String detail;
  final int? exitCode;

  @override
  String toString() => 'CliInstallException(${reason.name}${path.isEmpty ? '' : ' $path'}'
      '${detail.isEmpty ? '' : ': $detail'}${exitCode == null ? '' : ', exit $exitCode'})';
}

final class CliInstaller {
  CliInstaller({
    required this.cliPath,
    required this.home,
    String? os,
    String? shell,
    CliCommandRunner? runner,
    this.systemDir = '/usr/local/bin',
  })  : os = os ?? Platform.operatingSystem,
        shell = shell ?? Platform.environment['SHELL'] ?? '/bin/sh',
        _runner = runner ?? runWithTimeout;

  /// The CLI inside the app (`Antenna.app/Contents/Helpers/antenna`; on Linux, `bin/antenna` next to the window).
  final String cliPath;
  final String home;
  final String os;

  /// The owner's login shell (`$SHELL`): we read the terminal's PATH from it, because on macOS the window has its own
  /// PATH, inherited from launchd.
  final String shell;
  final String systemDir;
  final CliCommandRunner _runner;

  static const name = 'antenna';

  String get userBinDir => '$home/.local/bin';
  String get userLink => '$userBinDir/$name';
  String get systemLink => '$systemDir/$name';

  /// Installing into [systemDir] is offered only on macOS (the standard system password prompt).
  bool get offersSystemInstall => os == 'macos';

  CliLinkState _state(String link, {void Function(String?)? target}) {
    final type = FileSystemEntity.typeSync(link, followLinks: false);
    if (type == FileSystemEntityType.notFound) return CliLinkState.absent;
    if (type != FileSystemEntityType.link) return CliLinkState.otherFile;
    final t = Link(link).targetSync();
    target?.call(t);
    return t == cliPath ? CliLinkState.installed : CliLinkState.otherLink;
  }

  /// State of `~/.local/bin/antenna` (or [link]).
  Future<CliStatus> status({String? link}) async {
    final l = link ?? userLink;
    String? cur;
    final s = _state(l, target: (t) => cur = t);
    final dir = File(l).parent.path;
    return CliStatus(link: l, state: s, currentTarget: cur, inPath: await shellPathHas(dir));
  }

  /// Create `~/.local/bin/antenna` → [cliPath] (or replace an existing symlink, ours or not). A regular file is never
  /// touched. The replacement is atomic: a new link next to it, then `rename(2)` over the old one.
  Future<CliStatus> installUser() async {
    if (!File(cliPath).existsSync()) {
      throw CliInstallException(CliInstallFailure.notBundled, path: cliPath);
    }
    if (_state(userLink) == CliLinkState.otherFile) {
      throw CliInstallException(CliInstallFailure.userFileExists, path: userLink);
    }
    Directory(userBinDir).createSync(recursive: true);
    final tmp = '$userBinDir/.$name.tmp-$pid';
    final t = Link(tmp);
    if (FileSystemEntity.typeSync(tmp, followLinks: false) != FileSystemEntityType.notFound) t.deleteSync();
    t.createSync(cliPath);
    t.renameSync(userLink);
    _removePreviewLink();
    return status();
  }

  /// The `~/.local/bin/x` → `…/x.app/Contents/Helpers/x` link from the pre-release `x` instructions: after the rename
  /// it points nowhere (or at the old app). Only that exact link is removed, never anyone else's.
  void _removePreviewLink() {
    final old = '$userBinDir/x';
    if (FileSystemEntity.typeSync(old, followLinks: false) != FileSystemEntityType.link) return;
    if (Link(old).targetSync().endsWith('/x.app/Contents/Helpers/x')) Link(old).deleteSync();
  }

  /// AppleScript for `/usr/local/bin/antenna`: the standard macOS password prompt. Paths go through `quoted form of`;
  /// [prompt] is the line shown in the macOS password dialog (in the window's language).
  String adminScript(String prompt) {
    String lit(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    return 'do shell script "/bin/mkdir -p " & quoted form of ${lit(systemDir)} & '
        '" && /bin/ln -sfn " & quoted form of ${lit(cliPath)} & " " & quoted form of ${lit(systemLink)} '
        'with prompt ${lit(prompt)} '
        'with administrator privileges';
  }

  /// `/usr/local/bin/antenna` via the macOS password prompt ([prompt] is its text). A regular file there is never
  /// replaced. `false` means the owner cancelled the prompt.
  Future<bool> installSystem({required String prompt}) async {
    if (!offersSystemInstall) throw const CliInstallException(CliInstallFailure.macosOnly);
    if (_state(systemLink) == CliLinkState.otherFile) {
      throw CliInstallException(CliInstallFailure.systemFileExists, path: systemLink);
    }
    // The password prompt waits for the owner, so the limit is generous.
    final r = await _runner('/usr/bin/osascript', ['-e', adminScript(prompt)], timeout: const Duration(minutes: 5));
    if (r.exitCode == 0) return true;
    final err = '${r.stderr}'.trim();
    if (err.contains('-128')) return false; // "Cancel" in the password dialog
    throw CliInstallException(CliInstallFailure.osascript, detail: err, exitCode: r.exitCode);
  }

  /// Whether [dir] is in the PATH of the owner's login shell (what a new Terminal will see). `null` if it could not
  /// be determined.
  Future<bool?> shellPathHas(String dir) async {
    const marker = '__ANTENNA_PATH__';
    try {
      final r = await _runner(shell, ['-ilc', 'printf "\\n$marker%s\\n" "\$PATH"'], timeout: const Duration(seconds: 5));
      for (final line in '${r.stdout}'.split('\n')) {
        if (line.startsWith(marker)) {
          return line.substring(marker.length).split(':').any((p) => p == dir || p == '$dir/');
        }
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// A line for the shell profile when the directory is not in PATH.
  String pathHint() {
    final sh = shell.split('/').last;
    final profile = switch (sh) {
      'zsh' => '~/.zprofile',
      'bash' => os == 'macos' ? '~/.bash_profile' : '~/.bashrc',
      'fish' => null,
      _ => '~/.profile',
    };
    if (profile == null) return 'fish_add_path ~/.local/bin';
    return "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> $profile";
  }
}
