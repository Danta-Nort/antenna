// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for My devices (x-control/7, D-106; experimental): the page with this computer and its lending switch, the
// Mac mini with two requests waiting (one answered with Touch ID here, the other's text withheld because it holds a
// secret), and the build server with a problem, a key it offers and an update ready; and the dialog that revokes a
// lost computer, after another own computer reported it.

part of 'scenarios.dart';

Future<AppModel> _devicesModel({bool lostServer = false}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..protoVersion = 7
    ..devicesEnabled = true;
  final h = FakeTouchId();
  h.preset(h.dirFor(d.socketPath), d.ownerKeys);
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    updater: FakeCli().updater(cliPath: _bins.cli!),
    defaultSocket: d.socketPath,
    touchId: h,
  );
  await m.connect();
  d.devicesState = demoDevices(touchKeyId: d.ownerKeys.keys.values.first.keyId, lostServer: lostServer);
  await m.refreshDevices();
  return m;
}

Future<void> _devicesFrame(WidgetTester t, Widget app) async {
  await _frame(t, app);
  await t.tap(find.byKey(const Key('nav-devices')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void _defineDevicesScenarios() {
  Future<void> page(WidgetTester t, String name, {bool dark = false}) async {
    final m = await _devicesModel();
    await _devicesFrame(t, dark ? _dark(m) : XApp(model: m));
    await _snap(t, name);
  }

  _s('69_my_devices', (t) => page(t, '69_my_devices'));
  _s('69_my_devices_dark', (t) => page(t, '69_my_devices_dark', dark: true));

  Future<void> revoke(WidgetTester t, String name) async {
    final m = await _devicesModel(lostServer: true);
    await _devicesFrame(t, XApp(model: m));
    // The Mac mini folds, so the reported computer's banner is in view
    await t.tap(find.byKey(const Key('device-toggle-Mac mini')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('device-lost-revoke-build server')));
    await t.pump(const Duration(milliseconds: 400));
    // Touch ID is on in this model: the dialog confirms with one touch, the password one click away (D-131).
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  }

  _s('70_device_revoke', (t) => revoke(t, '70_device_revoke'));
}
