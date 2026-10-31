// SPDX-License-Identifier: AGPL-3.0-only
// An agent's working folders in memory and a git that only records what it was asked (Start an agent → "Set up this
// folder", host/agent_folder.dart): widget tests see exactly what would be written and run, with no disk and no git.
// The real disk and the real git are checked in test/host/agent_setup_test.dart.

import 'dart:io' show FileSystemException;

import 'package:antenna_desktop/host/agent_folder.dart';

class FakeAgentFolder implements AgentFolderFs {
  /// [dirExists]: folders that exist without being made here (the fake computer's working folders).
  FakeAgentFolder({bool Function(String path)? dirExists}) : _dirExists = dirExists ?? ((_) => false);

  final bool Function(String path) _dirExists;
  final dirs = <String>{};
  final files = <String, String>{};

  /// Every change, in order: `mkdir 0700 <path>`, `write <path>`, `copy <from> <to>`, `replace <path>`.
  final log = <String>[];

  @override
  bool isDir(String path) => dirs.contains(path) || _dirExists(path);

  @override
  bool exists(String path) => files.containsKey(path) || dirs.contains(path);

  @override
  String? readText(String path) => files[path];

  @override
  void createPrivateDir(String path) {
    dirs.add(path);
    log.add('mkdir 0700 $path');
  }

  @override
  void createDirs(String path) => dirs.add(path);

  @override
  void writeNew(String path, String content) {
    if (exists(path)) throw FileSystemException('File exists', path);
    files[path] = content;
    log.add('write $path');
  }

  @override
  void copy(String from, String to) {
    final text = files[from];
    if (text == null) throw FileSystemException('No such file', from);
    files[to] = text;
    log.add('copy $from $to');
  }

  @override
  void replace(String path, String content) {
    files[path] = content;
    log.add('replace $path');
  }
}

class FakeFolderGit implements AgentFolderGit {
  FakeFolderGit({this.folders});

  /// `git init` makes `.git` there.
  final FakeAgentFolder? folders;

  /// What git has in each folder's own config (dir → key → value).
  final config = <String, Map<String, String>>{};

  /// Every command run: (dir, argv).
  final runs = <(String, List<String>)>[];

  /// The exit code of every command from now on (not 0: a failing git).
  int exitCode = 0;

  @override
  Future<String?> localConfig(String dir, String key) async => config[dir]?[key];

  @override
  Future<int> run(String dir, List<String> argv) async {
    runs.add((dir, argv));
    if (exitCode != 0) return exitCode;
    switch (argv) {
      case ['git', 'init']:
        folders?.dirs.add('$dir/.git');
      case ['git', 'config', final key, final value]:
        (config[dir] ??= {})[key] = value;
    }
    return 0;
  }
}
