// SPDX-License-Identifier: AGPL-3.0-only
// Windows opens no unix socket at all (D-135: its afunix.sys bugchecks the machine when a process with a unix socket
// connection ends). The control client refuses before it tries, saying the daemon does not run there yet, and link
// forwarding between windows is off.
@TestOn('windows')
library;

import 'dart:io';

import 'package:antenna_desktop/host/links.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the control client refuses before it tries: no connect, so no WSAENETDOWN text', () async {
    final dir = Directory.systemTemp.createTempSync('antenna-win-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}\\antennad.sock';
    final client = XControlClient(path);
    await expectLater(
      client.hello(),
      throwsA(isA<XDaemonUnreachable>()
          .having((e) => e.message, 'message', contains('does not run on Windows yet'))
          .having((e) => e.socketPath, 'socketPath', path)),
    );
    expect(dir.listSync(), isEmpty);
  });

  test('no link forwarding between windows, even with XDG_RUNTIME_DIR set', () {
    final dir = Directory.systemTemp.createTempSync('antenna-win-');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(LinkRelay.pathFor({'XDG_RUNTIME_DIR': dir.path}), isNull);
  });
}
