// SPDX-License-Identifier: AGPL-3.0-only
// Touch ID for owner commands (D-102, CONTROL §22, experimental). On macOS the Runner (macos/Runner/TouchID.swift) does
// the CryptoKit work over the `antenna/touchid` channel: it creates a P-256 signing key and a key-agreement key in the
// Secure Enclave with `.privateKeyUsage` + `.biometryCurrentSet` (never `.userPresence`: the macOS password must not
// approve), keeps their wrapped blobs in a folder of the window (0700, files 0600), signs a proof's message after one
// touch, and seals or opens the unlock slot's key with HPKE to the agreement key. The private keys never leave the
// Secure Enclave; a blob is useless on another Mac. The message of a proof (`"antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖
// SHA-256(request)`) is built and hashed there, so the window needs no cryptography of its own. Linux has no such
// host ([NoTouchId]): the window offers no Touch ID at all.
//
// One folder per daemon socket (the window may talk to another daemon over ssh), under the window's support folder.
// Next to the blobs the window records which owner key the daemon enrolled (`owner_key.json`: its ID and whether an
// unlock slot was sealed); nothing in it is secret.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Why a Touch ID step did not happen (the screen turns it into words).
enum TouchIdFailure {
  /// The owner cancelled the prompt (or another app took the screen).
  cancelled,

  /// No Touch ID now: no sensor, the lid closed without a Touch ID keyboard, no Secure Enclave, an older Runner.
  unavailable,

  /// Too many failed touches: macOS wants the Mac's password before Touch ID works again.
  lockout,

  /// The key cannot be used any more: fingerprints were added or removed since it was created (`.biometryCurrentSet`).
  keyInvalidated,

  /// No fingerprint is set up on this Mac.
  notEnrolled,

  /// Anything else.
  failed;

  static TouchIdFailure parse(String code) => switch (code) {
        'cancelled' => TouchIdFailure.cancelled,
        'unavailable' => TouchIdFailure.unavailable,
        'lockout' => TouchIdFailure.lockout,
        'key_invalidated' => TouchIdFailure.keyInvalidated,
        'not_enrolled' => TouchIdFailure.notEnrolled,
        _ => TouchIdFailure.failed,
      };
}

final class TouchIdException implements Exception {
  const TouchIdException(this.reason, [this.detail = '']);
  final TouchIdFailure reason;

  /// The Runner's technical text (English), for the hint under the error.
  final String detail;

  @override
  String toString() => 'TouchIdException(${reason.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// What this Mac can do now, and the state of the window's key for one daemon.
final class TouchIdStatus {
  const TouchIdStatus({
    this.available = false,
    this.hpke = false,
    this.enrolled = false,
    this.domainChanged = false,
    this.reason,
  });

  factory TouchIdStatus.fromMap(Map<Object?, Object?> m) => TouchIdStatus(
        available: m['available'] == true,
        hpke: m['hpke'] == true,
        enrolled: m['enrolled'] == true,
        domainChanged: m['domainChanged'] == true,
        reason: m['reason'] is String ? m['reason']! as String : null,
      );

  /// No Touch ID host on this system.
  static const none = TouchIdStatus(reason: 'unsupported');

  /// A Secure Enclave and an enrolled fingerprint, usable now.
  final bool available;

  /// HPKE with a Secure Enclave key-agreement key (macOS 14 and later): the unlock slot can be sealed.
  final bool hpke;

  /// The window's key blobs for this daemon exist.
  final bool enrolled;

  /// The fingerprints changed since the keys were created (LocalAuthentication's domain state differs): the keys are
  /// dead.
  final bool domainChanged;

  /// Why not [available] (`no_secure_enclave`, `not_enrolled`, `lockout`, `unavailable`).
  final String? reason;
}

/// The keys the Runner created: the signing key's ID (first 8 bytes of SHA-256 of its 65-byte point, 16 hex, as the
/// daemon computes it) and both public keys (base64 of the X9.63 point).
final class TouchIdKeys {
  const TouchIdKeys({required this.keyId, required this.signingPublic, required this.agreementPublic});
  final String keyId;
  final String signingPublic;
  final String agreementPublic;
}

/// Which owner key the daemon enrolled for this folder, and whether its unlock slot was sealed here.
final class OwnerKeyRecord {
  const OwnerKeyRecord({required this.keyId, required this.unlock});

  static OwnerKeyRecord? fromJson(Object? j) {
    if (j is! Map<String, Object?>) return null;
    final id = j['key_id'];
    if (id is! String || !RegExp(r'^[0-9a-f]{16}$').hasMatch(id)) return null;
    return OwnerKeyRecord(keyId: id, unlock: j['unlock'] == true);
  }

  final String keyId;
  final bool unlock;

  Map<String, Object?> toJson() => {'key_id': keyId, 'unlock': unlock};
}

/// The Secure Enclave keys of the window, per daemon folder ([dirFor]).
abstract interface class TouchIdHost {
  /// This system can have Touch ID at all (macOS). `false` hides every Touch ID control.
  bool get supported;

  /// The folder of the keys for the daemon at [socketPath].
  String dirFor(String socketPath);

  Future<TouchIdStatus> status(String dir);

  /// Create both keys in the Secure Enclave (no prompt) and keep their blobs in [dir] (made 0700).
  Future<TouchIdKeys> create(String dir);

  /// One touch, with [reason] as the prompt's text ("“Antenna” is trying to …", the reason in its place), signs the proof's message
  /// for [nonce] (64 hex) and [request] (its exact text). [reuse]: the touch of the [openSlot] just before (within
  /// 30 s, once) instead of a new prompt. Returns base64 of the 64-byte `r ‖ s`.
  Future<String> sign({
    required String dir,
    required String nonce,
    required String request,
    required String reason,
    bool reuse = false,
  });

  /// Seal the unlock slot's key ([slotKey], base64 of 32 bytes) to the agreement key (HPKE); the window then drops it.
  Future<void> seal({required String dir, required String slotKey});

  /// One touch opens the sealed slot key (base64), and keeps that touch for one following [sign] with `reuse`.
  Future<String> openSlot({required String dir, required String reason});

  /// Remove the keys and the record of [dir].
  Future<void> delete(String dir);

  Future<OwnerKeyRecord?> readRecord(String dir);
  Future<void> writeRecord(String dir, OwnerKeyRecord record);
}

/// The folder name for a socket path: FNV-1a 64 of its UTF-8 bytes as 16 hex. Only a stable, short name, not a
/// security function: nothing depends on it being hard to invert.
String touchIdFolderName(String socketPath) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(socketPath)) {
    h ^= b;
    h *= 0x100000001b3;
  }
  // A Dart int is a signed 64-bit value: print the two 32-bit halves.
  String half(int v) => (v & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '${half(h >> 32)}${half(h)}';
}

/// The macOS Runner's Secure Enclave keys over `antenna/touchid`.
final class ChannelTouchId implements TouchIdHost {
  ChannelTouchId(this.root, {MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'antenna/touchid';

  /// The window's own folder for the keys (`~/Library/Application Support/Antenna/touchid`).
  final String root;
  final MethodChannel _channel;

  /// The macOS host, or [NoTouchId] elsewhere.
  static TouchIdHost forPlatform(Map<String, String> env) {
    final home = env['HOME'] ?? '';
    if (!Platform.isMacOS || home.isEmpty) return const NoTouchId();
    return ChannelTouchId('$home/Library/Application Support/Antenna/touchid');
  }

  @override
  bool get supported => true;

  @override
  String dirFor(String socketPath) => '$root/${touchIdFolderName(socketPath)}';

  Future<Object?> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException catch (e) {
      throw TouchIdException(TouchIdFailure.parse(e.code), e.message ?? '');
    } on MissingPluginException {
      throw const TouchIdException(TouchIdFailure.unavailable, 'this build has no Touch ID channel');
    }
  }

  static Map<Object?, Object?> _map(Object? r) =>
      r is Map ? r : throw const TouchIdException(TouchIdFailure.failed, 'unexpected reply');

  static String _string(Map<Object?, Object?> m, String k) =>
      m[k] is String ? m[k]! as String : throw TouchIdException(TouchIdFailure.failed, 'no $k in the reply');

  @override
  Future<TouchIdStatus> status(String dir) async {
    try {
      return TouchIdStatus.fromMap(_map(await _invoke('status', {'dir': dir})));
    } on TouchIdException catch (e) {
      // An older Runner: no Touch ID, nothing to show.
      if (e.reason == TouchIdFailure.unavailable) return const TouchIdStatus(reason: 'unavailable');
      rethrow;
    }
  }

  @override
  Future<TouchIdKeys> create(String dir) async {
    final m = _map(await _invoke('create', {'dir': dir}));
    return TouchIdKeys(
      keyId: _string(m, 'keyId'),
      signingPublic: _string(m, 'signingPublic'),
      agreementPublic: _string(m, 'agreementPublic'),
    );
  }

  @override
  Future<String> sign({
    required String dir,
    required String nonce,
    required String request,
    required String reason,
    bool reuse = false,
  }) async =>
      _string(_map(await _invoke('sign', {'dir': dir, 'nonce': nonce, 'request': request, 'reason': reason, 'reuse': reuse})),
          'sig');

  @override
  Future<void> seal({required String dir, required String slotKey}) async =>
      _invoke('seal', {'dir': dir, 'slotKey': slotKey});

  @override
  Future<String> openSlot({required String dir, required String reason}) async =>
      _string(_map(await _invoke('openSlot', {'dir': dir, 'reason': reason})), 'slotKey');

  @override
  Future<void> delete(String dir) async {
    try {
      File('$dir/$_record').deleteSync();
    } on FileSystemException {
      // Already gone.
    }
    await _invoke('delete', {'dir': dir});
  }

  static const _record = 'owner_key.json';

  @override
  Future<OwnerKeyRecord?> readRecord(String dir) async {
    try {
      return OwnerKeyRecord.fromJson(jsonDecode(await File('$dir/$_record').readAsString()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeRecord(String dir, OwnerKeyRecord record) async {
    // The folder is the Runner's (0700, made by `create`); the record holds no secret. Written whole, then renamed.
    final tmp = File('$dir/$_record.tmp');
    await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
    await tmp.rename('$dir/$_record');
  }
}

/// No Touch ID on this system (Linux): nothing is offered.
final class NoTouchId implements TouchIdHost {
  const NoTouchId();

  static const _no = TouchIdException(TouchIdFailure.unavailable, 'no Touch ID on this system');

  @override
  bool get supported => false;

  @override
  String dirFor(String socketPath) => '';

  @override
  Future<TouchIdStatus> status(String dir) async => TouchIdStatus.none;

  @override
  Future<TouchIdKeys> create(String dir) async => throw _no;

  @override
  Future<String> sign({
    required String dir,
    required String nonce,
    required String request,
    required String reason,
    bool reuse = false,
  }) async =>
      throw _no;

  @override
  Future<void> seal({required String dir, required String slotKey}) async => throw _no;

  @override
  Future<String> openSlot({required String dir, required String reason}) async => throw _no;

  @override
  Future<void> delete(String dir) async {}

  @override
  Future<OwnerKeyRecord?> readRecord(String dir) async => null;

  @override
  Future<void> writeRecord(String dir, OwnerKeyRecord record) async {}
}
