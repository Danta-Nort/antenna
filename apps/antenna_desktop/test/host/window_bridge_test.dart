// SPDX-License-Identifier: AGPL-3.0-only
// The window bridge's command line on Windows (D-135): the window passes only what it was given and never computes a
// pipe name; one bridge per daemon. Runs on every system.

import 'package:antenna_desktop/host/window_bridge.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bridge gets --data-dir and --socket only when they were given', () {
    expect(windowBridgeArgs({'LOCALAPPDATA': r'C:\Users\u\AppData\Local'}), isEmpty);
    expect(windowBridgeArgs({'ANTENNA_DATA_DIR': r'D:\a'}), ['--data-dir', r'D:\a']);
    expect(windowBridgeArgs({'ANTENNA_SOCKET': r'\\.\pipe\antenna-test'}), ['--socket', r'\\.\pipe\antenna-test']);
    expect(
      windowBridgeArgs({'ANTENNA_DATA_DIR': r'D:\a', 'ANTENNA_SOCKET': r'\\.\pipe\p'}),
      ['--data-dir', r'D:\a', '--socket', r'\\.\pipe\p'],
    );
    expect(windowBridgeArgs({'ANTENNA_DATA_DIR': '', 'ANTENNA_SOCKET': ''}), isEmpty);
    // A socket chosen in the window wins over the environment's.
    expect(windowBridgeArgs({'ANTENNA_SOCKET': r'\\.\pipe\p'}, socket: r'\\.\pipe\q'), ['--socket', r'\\.\pipe\q']);
    // The legacy variables are the CLI's own fallbacks, read from the environment it inherits.
    expect(windowBridgeArgs({'X_SOCKET': '/s', 'X_DATA_DIR': '/d'}), isEmpty);
  });

  test('one bridge per daemon: the default one resolves itself, another socket is passed', () {
    final made = <(String, String)>[];
    final bridges = WindowBridges(
      cli: r'C:\Program Files\Antenna\antenna.exe',
      env: const {'LOCALAPPDATA': r'C:\Users\u\AppData\Local'},
      defaultSocket: r'C:\Users\u\AppData\Local\Antenna\antennad.sock',
      make: (cli, arguments) {
        made.add((cli, arguments.join(' ')));
        return BridgeMux(() => throw UnimplementedError());
      },
    );
    final a = bridges.forSocket(r'C:\Users\u\AppData\Local\Antenna\antennad.sock');
    expect(bridges.forSocket(r'C:\Users\u\AppData\Local\Antenna\antennad.sock'), same(a));
    final b = bridges.forSocket(r'\\.\pipe\antenna-other');
    expect(b, isNot(same(a)));
    expect(made, [
      (r'C:\Program Files\Antenna\antenna.exe', ''),
      (r'C:\Program Files\Antenna\antenna.exe', r'--socket \\.\pipe\antenna-other'),
    ]);
  });
}
