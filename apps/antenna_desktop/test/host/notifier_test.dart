// SPDX-License-Identifier: AGPL-3.0-only
// System notifications (D-84). Linux: a real D-Bus round trip — an in-process bus (package:dbus DBusServer) with a
// stand-in org.freedesktop.Notifications service, so the exact `Notify` call the window makes is checked without a
// desktop. macOS: the osascript command (there is no macOS here) run through a stand-in executor.

import 'dart:io';

import 'package:antenna_desktop/host/notifier.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

/// org.freedesktop.Notifications as a desktop implements it: records the calls, answers with an ID.
class _Notifications extends DBusObject {
  _Notifications() : super(DBusObjectPath('/org/freedesktop/Notifications'));
  final calls = <DBusMethodCall>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall c) async {
    if (c.interface == 'org.freedesktop.Notifications' && c.name == 'Notify') {
      calls.add(c);
      return DBusMethodSuccessResponse([const DBusUint32(42)]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  test('texts are one short line', () {
    expect(notificationText('a\nb\t c\u0007'), 'a b c');
    expect(notificationText('x' * 300).length, 200);
  });

  group('Linux, org.freedesktop.Notifications', () {
    late Directory dir;
    late DBusServer server;
    late DBusAddress address;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('antenna-dbus-');
      server = DBusServer();
      address = await server.listenAddress(DBusAddress.unix(path: '${dir.path}/bus'));
    });

    tearDown(() async {
      await server.close();
      await dir.delete(recursive: true);
    });

    test('the Notify call reaches the service: facts only, tied to the app', () async {
      final service = DBusClient(address);
      addTearDown(service.close);
      final fake = _Notifications();
      await service.requestName('org.freedesktop.Notifications');
      await service.registerObject(fake);

      final n = FreedesktopNotifier(busAddress: address.value);
      await n.show(
        title: 'Antenna: approval needed',
        body: 'claude-backend is waiting for your approval:\nsend a message → Emily',
      );
      expect(n.lastResult, 'shown: id 42');
      final c = fake.calls.single;
      expect(c.signature, DBusSignature('susssasa{sv}i'));
      expect(c.values[0].asString(), 'Antenna');
      expect(c.values[2].asString(), linuxAppId);
      expect(c.values[3].asString(), 'Antenna: approval needed');
      expect(c.values[4].asString(), 'claude-backend is waiting for your approval: send a message → Emily');
      expect(c.values[6].asStringVariantDict()['desktop-entry']?.asString(), linuxAppId);
    });

    test('no notification service on the bus: nothing is shown, nothing is thrown', () async {
      final n = FreedesktopNotifier(busAddress: address.value);
      await n.show(title: 't', body: 'b');
      expect(n.lastResult, startsWith('not shown'));
    });
    // The in-process bus authenticates with the Linux peer credentials; the window uses osascript on macOS anyway.
  }, skip: Platform.isLinux ? false : 'a Linux D-Bus round trip');

  test('Linux: no session bus at all is not an error', () async {
    final dir = await Directory.systemTemp.createTemp('antenna-nobus-');
    addTearDown(() => dir.delete(recursive: true));
    final n = FreedesktopNotifier(busAddress: 'unix:path=${dir.path}/missing');
    await n.show(title: 't', body: 'b');
    expect(n.lastResult, startsWith('not shown'));
  }, skip: Platform.isWindows ? 'no unix socket on Windows (D-135)' : false);

  group('macOS, osascript', () {
    test('the texts are script arguments, never script text', () {
      final (exe, args) = MacosNotifier.command(title: 'Antenna: approval needed', body: 'x" & do shell script "id');
      expect(exe, '/usr/bin/osascript');
      expect(args.sublist(0, 6), [
        '-e', 'on run argv',
        '-e', 'display notification (item 2 of argv) with title (item 1 of argv)',
        '-e', 'end run',
      ]);
      expect(args.sublist(6), ['Antenna: approval needed', 'x" & do shell script "id']);
    });

    test('runs osascript once; a failure is not thrown', () async {
      final ran = <List<String>>[];
      final n = MacosNotifier(run: (exe, args, {required timeout}) async {
        ran.add([exe, ...args]);
        return ProcessResult(1, 0, '', '');
      });
      await n.show(title: 'T', body: 'B\nC');
      expect(ran.single.first, '/usr/bin/osascript');
      expect(ran.single.sublist(ran.single.length - 2), ['T', 'B C']);
      expect(n.lastResult, 'exit 0');
      final failing = MacosNotifier(run: (exe, args, {required timeout}) async => throw const OSError('no osascript'));
      await failing.show(title: 'T', body: 'B');
      expect(failing.lastResult, startsWith('not shown'));
    });
  });
}
