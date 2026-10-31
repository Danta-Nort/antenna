// SPDX-License-Identifier: AGPL-3.0-only
// Restarting an app after Connect, on macOS, with the commands recorded instead of run: the bundle ID comes from the
// app's own Info.plist, `is running` asks without launching it, Quit is the app's own (an Apple Event), the window
// waits for the exit, refusals are told apart (Automation not allowed, the app still open), and a bundle ID that is
// not reverse DNS never reaches an AppleScript. Elsewhere the window does not claim to know.

import 'dart:io';

import 'package:antenna_desktop/host/app_connect.dart';
import 'package:flutter_test/flutter_test.dart';

const _app = '/Applications/Claude.app';
const _id = 'com.anthropic.claudefordesktop';

/// A Mac where `osascript` and `defaults` answer from [running] and [quitAnswer].
final class _Mac {
  _Mac({this.id = _id});
  final String id;
  bool running = true;

  /// The quit command's (exit code, stderr); a successful quit also stops the app.
  (int, String) quitAnswer = (0, '');
  final calls = <List<String>>[];

  Future<ProcessResult> run(String exe, List<String> args, {required Duration timeout}) async {
    calls.add([exe, ...args]);
    if (exe == '/usr/bin/defaults') return ProcessResult(1, 0, '$id\n', '');
    if (exe == '/usr/bin/osascript') {
      final script = args.last;
      if (script.endsWith('is running')) return ProcessResult(1, 0, '$running\n', '');
      if (script.endsWith('to quit')) {
        final (code, err) = quitAnswer;
        if (code == 0) running = false;
        return ProcessResult(1, code, '', err);
      }
    }
    if (exe == 'open') {
      running = true;
      return ProcessResult(1, 0, '', '');
    }
    return ProcessResult(1, 1, '', 'unexpected');
  }

  SystemAppLauncher launcher({bool macos = true}) =>
      SystemAppLauncher(run: run, macos: macos, poll: const Duration(milliseconds: 1));
}

void main() {
  test('running, quit, wait for the exit, open: the commands, in order', () async {
    final mac = _Mac();
    final l = mac.launcher();
    expect(await l.appRunning(_app), isTrue);
    expect(await l.quitApp(_app, timeout: const Duration(seconds: 2)), AppQuitResult.quit);
    expect(await l.appRunning(_app), isFalse);
    expect(await l.openApp(_app), isTrue);
    expect(mac.calls, [
      ['/usr/bin/defaults', 'read', '$_app/Contents/Info', 'CFBundleIdentifier'],
      ['/usr/bin/osascript', '-e', 'application id "$_id" is running'],
      ['/usr/bin/osascript', '-e', 'tell application id "$_id" to quit'],
      ['/usr/bin/osascript', '-e', 'application id "$_id" is running'],
      ['/usr/bin/osascript', '-e', 'application id "$_id" is running'],
      ['open', '-a', _app],
    ], reason: 'the bundle ID is read once; nothing is killed');
  });

  test('Automation not allowed (-1743), a cancelled quit (-128) and an app that stays open', () async {
    final denied = _Mac()..quitAnswer = (1, 'execution error: Not authorized to send Apple events to Claude. (-1743)');
    expect(await denied.launcher().quitApp(_app), AppQuitResult.notAllowed);

    final cancelled = _Mac()..quitAnswer = (1, 'execution error: User canceled. (-128)');
    expect(await cancelled.launcher().quitApp(_app, timeout: const Duration(milliseconds: 50)), AppQuitResult.stillRunning);

    final odd = _Mac()..quitAnswer = (1, 'execution error: something else (-600)');
    expect(await odd.launcher().quitApp(_app), AppQuitResult.failed);
  });

  test('a bundle ID that is not reverse DNS never reaches osascript', () async {
    final mac = _Mac(id: 'x" to do shell script "touch /tmp/pwned');
    final l = mac.launcher();
    expect(await l.appRunning(_app), isNull);
    expect(await l.quitApp(_app), AppQuitResult.failed);
    expect(mac.calls.where((c) => c.first == '/usr/bin/osascript'), isEmpty);
  });

  test('not macOS: the window cannot tell, does not quit and does not open', () async {
    final mac = _Mac();
    final l = mac.launcher(macos: false);
    expect(await l.appRunning('/usr/bin/claude-desktop'), isNull);
    expect(await l.quitApp('/usr/bin/claude-desktop'), AppQuitResult.failed);
    expect(await l.openApp('/usr/bin/claude-desktop'), isFalse);
    expect(mac.calls, isEmpty);
  });
}
