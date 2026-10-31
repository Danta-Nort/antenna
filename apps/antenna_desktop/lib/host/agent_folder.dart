// SPDX-License-Identifier: AGPL-3.0-only
// An agent's working folder on this computer: the few file operations "Set up this folder" does
// (state/agent_setup.dart) and the git it runs there, behind interfaces so a widget test uses a fake and a host test a
// temporary folder. No shell anywhere: git gets its arguments as a list.

import 'dart:io';

/// The file operations of a folder setup. Paths are absolute; failures throw [FileSystemException].
abstract interface class AgentFolderFs {
  /// [path] is a folder (a link to one counts, as for any working folder).
  bool isDir(String path);

  /// Something is at [path], not following a link there (a dangling link counts: nothing is written through it).
  bool exists(String path);

  /// The text of the file at [path]; `null` when nothing is there.
  String? readText(String path);

  /// Creates [path] and its parents; [path] itself only this user can open (0700).
  void createPrivateDir(String path);

  /// Creates [path] and its parents with the usual mode.
  void createDirs(String path);

  /// Writes a new file: never over anything at [path], never through a link at its name.
  void writeNew(String path, String content);

  /// Copies the file [from] to [to], replacing [to].
  void copy(String from, String to);

  /// Replaces the file at [path] with [content] in one step: written next to it, then renamed into place, so the file
  /// is either the old one or the new one.
  void replace(String path, String content);
}

/// git for a folder setup.
abstract interface class AgentFolderGit {
  /// `git config --local --get <key>` in [dir]: the value, or `null` (not set, no repository, no git).
  Future<String?> localConfig(String dir, String key);

  /// Runs [argv] (`git …`) in [dir], without a shell and without input; returns its exit code. Throws
  /// [ProcessException] when it cannot be started.
  Future<int> run(String dir, List<String> argv);
}

/// Creates [path] if it is missing and makes it private (0700). dart:io has no chmod of its own (see
/// outgoing_staging.dart), so the mode is set explicitly when the folder is new or was not already private. On Windows
/// a folder under the user's profile takes the profile's entries (the user, SYSTEM and the Administrators), which keep
/// other users out as 0700 does, so nothing is changed there.
void createPrivateFolder(String path) {
  final dir = Directory(path);
  var type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    dir.createSync(recursive: true);
    type = FileSystemEntity.typeSync(path, followLinks: false);
  }
  if (type != FileSystemEntityType.directory) throw FileSystemException('not a folder', path);
  if (Platform.isWindows) return;
  if (dir.statSync().mode & 0x3F != 0) {
    final r = Process.runSync('/bin/chmod', ['700', path]);
    if (r.exitCode != 0) throw FileSystemException('chmod 700: ${r.stderr}', path);
  }
}

/// The real disk.
final class DiskAgentFolder implements AgentFolderFs {
  const DiskAgentFolder();

  @override
  bool isDir(String path) => FileSystemEntity.isDirectorySync(path);

  @override
  bool exists(String path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

  @override
  String? readText(String path) {
    if (!exists(path)) return null;
    return File(path).readAsStringSync();
  }

  @override
  void createPrivateDir(String path) => createPrivateFolder(path);

  @override
  void createDirs(String path) => Directory(path).createSync(recursive: true);

  @override
  void writeNew(String path, String content) {
    // `exclusive`: O_CREAT|O_EXCL, which fails on anything at the name, a link included.
    final f = File(path)..createSync(exclusive: true);
    f.writeAsStringSync(content, flush: true);
  }

  @override
  void copy(String from, String to) => File(from).copySync(to);

  @override
  void replace(String path, String content) {
    final slash = path.lastIndexOf('/');
    final tmp = '${path.substring(0, slash + 1)}.${path.substring(slash + 1)}.antenna-$pid';
    final t = File(tmp);
    if (exists(tmp)) t.deleteSync();
    writeNew(tmp, content);
    try {
      t.renameSync(path);
    } on FileSystemException {
      if (exists(tmp)) t.deleteSync();
      rethrow;
    }
  }
}

/// git as a program: the one the agent CLIs are found with ([locate], which also reads the login shell's PATH), or
/// `git` from the window's PATH.
final class ProcessAgentFolderGit implements AgentFolderGit {
  const ProcessAgentFolderGit({this.locate});

  /// Where a program is (`null`: not found there, so the window's PATH decides).
  final String? Function(String name)? locate;

  String _exe(String name) => locate?.call(name) ?? name;

  @override
  Future<String?> localConfig(String dir, String key) async {
    try {
      final r = await Process.run(_exe('git'), ['-C', dir, 'config', '--local', '--get', key]);
      return r.exitCode == 0 ? (r.stdout as String).trim() : null;
    } on ProcessException {
      return null;
    }
  }

  @override
  Future<int> run(String dir, List<String> argv) async {
    final r = await Process.run(_exe(argv.first), argv.sublist(1), workingDirectory: dir);
    return r.exitCode;
  }
}
