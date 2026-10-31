// SPDX-License-Identifier: AGPL-3.0-only
// The macOS title bar follows the app's theme (WindowChrome, MainFlutterWindow.swift): the window sends the theme and
// the navigation's color when the palette changes, once per change, and nothing on other systems.

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/window_chrome.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/theme/x_theme.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

const _bins = CoreBinaries(daemon: '/opt/antenna/antennad', cli: '/opt/antenna/antenna', bundled: true);

Future<AppModel> _model() async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
  );
  await m.connect();
  return m;
}

void main() {
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    WindowChrome.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(WindowChrome.channel,
        (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(WindowChrome.channel, null);
    WindowChrome.enabled = false;
    WindowChrome.reset();
  });

  testWidgets('macOS: the title bar gets the app theme and the navigation color, once per change', (t) async {
    WindowChrome.enabled = true;
    final look = Appearance(initial: ThemeChoice.light);
    await t.pumpWidget(XApp(model: await _model(), appearance: look));
    await t.pump(const Duration(milliseconds: 300));
    expect(calls.map((c) => c.method), ['chrome']);
    expect(calls.single.arguments, {'dark': false, 'color': XPalette.light.nav.toARGB32()});
    look.choice = ThemeChoice.dark;
    await t.pump(const Duration(milliseconds: 300));
    expect(calls, hasLength(2), reason: 'rebuilds send nothing new');
    expect(calls.last.arguments, {'dark': true, 'color': XPalette.dark.nav.toARGB32()});
  });

  testWidgets('other systems: nothing is sent', (t) async {
    WindowChrome.enabled = false;
    await t.pumpWidget(XApp(model: await _model(), appearance: Appearance(initial: ThemeChoice.dark)));
    await t.pump(const Duration(milliseconds: 300));
    expect(calls, isEmpty);
  });

  test('a Runner without the handler is not an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(WindowChrome.channel, null);
    WindowChrome.enabled = true;
    await WindowChrome.apply(dark: true, color: XPalette.dark.nav);
  });
}
