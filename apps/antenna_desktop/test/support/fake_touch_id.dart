// SPDX-License-Identifier: AGPL-3.0-only
// A fake Secure Enclave for widget tests and golden frames: keys in memory, a "signature" the fake daemon recognizes
// ([fakeSig]: the key, the challenge and the exact request text), every prompt recorded with its reason, and the next
// prompt's failure chosen by the test. The real one is macos/Runner/TouchID.swift, checked on a Mac.

import 'package:antenna_desktop/host/touch_id.dart';

import 'fake_owner_keys.dart';

/// One prompt the owner would have seen (or a reused touch, which shows none).
final class FakePrompt {
  const FakePrompt(this.method, this.reason, {this.reuse = false, this.request});
  final String method;
  final String reason;
  final bool reuse;
  final String? request;

  /// A Touch ID sheet was shown (a reused touch shows none).
  bool get shown => !reuse;
}

final class FakeTouchId implements TouchIdHost {
  FakeTouchId({this.available = true, this.hpke = true, this.system = true});

  /// `false`: a system without Touch ID (Linux) whose host would still answer if asked.
  final bool system;

  /// A sensor and a fingerprint, usable now.
  bool available;
  bool hpke;

  /// The fingerprints changed since the keys were made.
  bool domainChanged = false;

  /// The next prompt fails with this reason (then it is cleared).
  TouchIdFailure? nextFailure;

  /// How long the owner takes to touch the sensor.
  Duration touchTakes = Duration.zero;

  /// Every prompt (sign, openSlot) with its reason.
  final prompts = <FakePrompt>[];

  /// Method calls in order.
  final calls = <String>[];

  final _keys = <String, String>{}; // dir → signing public key
  final _slots = <String, String>{}; // dir → sealed slot key
  final _records = <String, OwnerKeyRecord>{};
  var _made = 0;
  bool _reusable = false;

  String? slotOf(String dir) => _slots[dir];
  String? publicKeyOf(String dir) => _keys[dir];

  /// Set up a key for [dir] as if enrolled earlier (goldens, gate tests).
  void preset(String dir, FakeOwnerKeys daemonKeys, {bool unlock = true}) {
    final pub = 'BFake${++_made}';
    _keys[dir] = pub;
    final added = daemonKeys.add(pub, 'touchid@mac', unlock: unlock);
    if (added.slotKey case final s?) _slots[dir] = s;
    _records[dir] = OwnerKeyRecord(keyId: added.key.keyId, unlock: unlock);
  }

  @override
  bool get supported => system;

  @override
  String dirFor(String socketPath) => '/Users/owner/Library/Application Support/Antenna/touchid/${touchIdFolderName(socketPath)}';

  @override
  Future<TouchIdStatus> status(String dir) async {
    calls.add('status');
    return TouchIdStatus(
      available: available,
      hpke: hpke,
      enrolled: _keys.containsKey(dir),
      domainChanged: _keys.containsKey(dir) && domainChanged,
      reason: available ? null : 'unavailable',
    );
  }

  @override
  Future<TouchIdKeys> create(String dir) async {
    calls.add('create');
    final pub = 'BFake${++_made}';
    _keys[dir] = pub;
    _slots.remove(dir);
    return TouchIdKeys(keyId: fakeKeyId(pub), signingPublic: pub, agreementPublic: 'BAgree$_made');
  }

  void _prompt(String method, String reason, {bool reuse = false, String? request}) {
    prompts.add(FakePrompt(method, reason, reuse: reuse, request: request));
    if (reuse) return;
    if (!available) throw const TouchIdException(TouchIdFailure.unavailable);
    if (domainChanged) throw const TouchIdException(TouchIdFailure.keyInvalidated);
    final f = nextFailure;
    nextFailure = null;
    if (f != null) throw TouchIdException(f);
  }

  @override
  Future<String> sign({
    required String dir,
    required String nonce,
    required String request,
    required String reason,
    bool reuse = false,
  }) async {
    calls.add('sign');
    final pub = _keys[dir];
    if (pub == null) throw const TouchIdException(TouchIdFailure.keyInvalidated);
    final reused = reuse && _reusable;
    _reusable = false;
    _prompt('sign', reason, reuse: reused, request: request);
    if (!reused && touchTakes > Duration.zero) await Future<void>.delayed(touchTakes);
    return fakeSig(pub, nonce, request);
  }

  @override
  Future<void> seal({required String dir, required String slotKey}) async {
    calls.add('seal');
    if (!hpke) throw const TouchIdException(TouchIdFailure.unavailable);
    _slots[dir] = slotKey;
  }

  @override
  Future<String> openSlot({required String dir, required String reason}) async {
    calls.add('openSlot');
    _reusable = false;
    _prompt('openSlot', reason);
    final s = _slots[dir];
    if (s == null) throw const TouchIdException(TouchIdFailure.keyInvalidated);
    _reusable = true;
    return s;
  }

  @override
  Future<void> delete(String dir) async {
    calls.add('delete');
    _keys.remove(dir);
    _slots.remove(dir);
    _records.remove(dir);
  }

  @override
  Future<OwnerKeyRecord?> readRecord(String dir) async => _records[dir];

  @override
  Future<void> writeRecord(String dir, OwnerKeyRecord record) async => _records[dir] = record;

  /// The Touch ID sheets shown so far.
  int get shown => prompts.where((p) => p.shown).length;
}
