// SPDX-License-Identifier: AGPL-3.0-only
// The Touch ID host on the window's side (lib/host/touch_id.dart): what goes over `antenna/touchid` to the macOS Runner
// (TouchID.swift), how its errors become reasons, the per-daemon folder, the owner key record, and no Touch ID on
// Linux. The Secure Enclave itself is checked on a Mac.

import 'dart:io';

import 'package:antenna_desktop/host/touch_id.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(ChannelTouchId.channelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Directory tmp;

  setUp(() async {
    calls = [];
    tmp = await Directory.systemTemp.createTemp('antenna-touchid-');
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await tmp.delete(recursive: true);
  });

  test('the arguments of each method, and the replies read back', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'status' => {'available': true, 'hpke': true, 'enrolled': false, 'domainChanged': false},
        'create' => {'keyId': '01b3e9c533123cb8', 'signingPublic': 'BPcp', 'agreementPublic': 'BAgr'},
        'sign' => {'sig': 'c2ln'},
        'openSlot' => {'slotKey': 'c2xvdA=='},
        _ => null,
      };
    });
    final h = ChannelTouchId(tmp.path);
    final dir = h.dirFor('/Users/emily/.local/share/antenna/antennad.sock');
    expect(dir, '${tmp.path}/${touchIdFolderName('/Users/emily/.local/share/antenna/antennad.sock')}');
    final st = await h.status(dir);
    expect((st.available, st.hpke, st.enrolled, st.domainChanged), (true, true, false, false));
    final keys = await h.create(dir);
    expect((keys.keyId, keys.signingPublic, keys.agreementPublic), ('01b3e9c533123cb8', 'BPcp', 'BAgr'));
    expect(
      await h.sign(dir: dir, nonce: 'ab' * 32, request: '{"cmd":"login","password":"","hold":true}', reason: 'sign in'),
      'c2ln',
    );
    await h.seal(dir: dir, slotKey: 'c2xvdA==');
    expect(await h.openSlot(dir: dir, reason: 'unlock Antenna and sign in'), 'c2xvdA==');
    await h.delete(dir);
    expect([for (final c in calls) c.method], ['status', 'create', 'sign', 'seal', 'openSlot', 'delete']);
    expect(calls[2].arguments, {
      'dir': dir,
      'nonce': 'ab' * 32,
      'request': '{"cmd":"login","password":"","hold":true}',
      'reason': 'sign in',
      'reuse': false,
    });
    expect(calls[3].arguments, {'dir': dir, 'slotKey': 'c2xvdA=='});
    expect(calls[4].arguments, {'dir': dir, 'reason': 'unlock Antenna and sign in'});
  });

  test("the Runner's error codes become reasons; an older Runner means no Touch ID", () async {
    var code = 'cancelled';
    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: code, message: 'm'));
    final h = ChannelTouchId(tmp.path);
    for (final (c, want) in [
      ('cancelled', TouchIdFailure.cancelled),
      ('unavailable', TouchIdFailure.unavailable),
      ('lockout', TouchIdFailure.lockout),
      ('key_invalidated', TouchIdFailure.keyInvalidated),
      ('not_enrolled', TouchIdFailure.notEnrolled),
      ('failed', TouchIdFailure.failed),
      ('something_new', TouchIdFailure.failed),
    ]) {
      code = c;
      await expectLater(
        h.sign(dir: tmp.path, nonce: 'ab' * 32, request: '{}', reason: 'x'),
        throwsA(isA<TouchIdException>().having((e) => e.reason, 'reason', want)),
      );
    }
    messenger.setMockMethodCallHandler(channel, null);
    final st = await h.status(tmp.path);
    expect(st.available, isFalse, reason: 'no handler: a Runner without Touch ID');
    await expectLater(h.create(tmp.path), throwsA(isA<TouchIdException>()));
  });

  test('the owner key record: written whole, read back, anything malformed is no record', () async {
    final h = ChannelTouchId(tmp.path);
    expect(await h.readRecord(tmp.path), isNull);
    await h.writeRecord(tmp.path, const OwnerKeyRecord(keyId: '01b3e9c533123cb8', unlock: true));
    final r = await h.readRecord(tmp.path);
    expect((r?.keyId, r?.unlock), ('01b3e9c533123cb8', true));
    expect(File('${tmp.path}/owner_key.json.tmp').existsSync(), isFalse);
    File('${tmp.path}/owner_key.json').writeAsStringSync('{"key_id":"../../x","unlock":true}');
    expect(await h.readRecord(tmp.path), isNull, reason: 'only 16 hex is a key ID');
    File('${tmp.path}/owner_key.json').writeAsStringSync('not json');
    expect(await h.readRecord(tmp.path), isNull);
  });

  test('one folder per daemon socket, stable across runs', () {
    expect(touchIdFolderName('/a.sock'), touchIdFolderName('/a.sock'));
    expect(touchIdFolderName('/a.sock'), isNot(touchIdFolderName('/b.sock')));
    expect(touchIdFolderName('/a.sock'), matches(RegExp(r'^[0-9a-f]{16}$')));
    // FNV-1a 64 of the empty string is its offset basis.
    expect(touchIdFolderName(''), 'cbf29ce484222325');
  });

  test('Linux: no Touch ID host at all', () async {
    const h = NoTouchId();
    expect(h.supported, isFalse);
    expect((await h.status('')).available, isFalse);
    expect(await h.readRecord(''), isNull);
    await expectLater(h.create(''), throwsA(isA<TouchIdException>()));
    expect(ChannelTouchId.forPlatform(const {'HOME': '/home/emily'}).supported, Platform.isMacOS);
  });
}
