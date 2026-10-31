// SPDX-License-Identifier: AGPL-3.0-only
// The real pseudo-terminal in `flutter test`: flutter_tester does not build plugins' native code, so the live Code mode
// test compiles flutter_pty's C sources (from the pub cache) with the system compiler and loads the library first.
// The plugin then opens the library by name and gets the one already loaded: on Linux by its soname
// (`libflutter_pty.so`), on macOS by the framework path it uses as the dylib's install name
// (`flutter_pty.framework/flutter_pty`). Linux and macOS.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

bool _loaded = false;

/// Build and load flutter_pty's library (once per test process). Returns `null` on success, otherwise why not.
Future<String?> loadPtyLibrary() async {
  if (_loaded) return null;
  if (!Platform.isLinux && !Platform.isMacOS) return 'the live terminal test runs on Linux and macOS';
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return 'no .dart_tool/package_config.json (run flutter pub get)';
  final packages = (json.decode(config.readAsStringSync()) as Map<String, Object?>)['packages']! as List<Object?>;
  final pkg = packages.cast<Map<String, Object?>>().firstWhere((p) => p['name'] == 'flutter_pty');
  final root = config.parent.uri.resolve('${pkg['rootUri']}/').toFilePath();
  final source = '${root}src/flutter_pty.c';
  if (!File(source).existsSync()) return 'flutter_pty sources not found at $source';
  final out = Directory.systemTemp.createTempSync('antenna-pty-');
  // macOS: a .dylib whose install name is the framework path the plugin opens (`DynamicLibrary.open` then matches this
  // already-loaded image by that name). Linux: a .so with the soname the plugin opens.
  final lib = '${out.path}/${Platform.isMacOS ? 'flutter_pty.dylib' : 'libflutter_pty.so'}';
  final r = await Process.run(
      'cc',
      Platform.isMacOS
          ? ['-dynamiclib', '-O1', '-DDART_SHARED_LIB', '-install_name', 'flutter_pty.framework/flutter_pty', '-o', lib, source, '-lpthread']
          : ['-shared', '-fPIC', '-O1', '-DDART_SHARED_LIB', '-Wl,-soname,libflutter_pty.so', '-o', lib, source, '-lpthread']);
  if (r.exitCode != 0) {
    out.deleteSync(recursive: true);
    return 'cc failed: ${r.stderr}';
  }
  DynamicLibrary.open(lib);
  _loaded = true;
  // The loaded library stays mapped; the file is not needed any more.
  out.deleteSync(recursive: true);
  return null;
}
