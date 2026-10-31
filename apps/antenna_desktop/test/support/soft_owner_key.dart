// SPDX-License-Identifier: AGPL-3.0-only
// The Secure Enclave replaced by the published owner test key in software, for live tests against a real daemon
// (CONTROL §22.5: only a debug build started with ANTENNA_OWNER_TEST_KEY=1 accepts the test key). Signatures are made
// by `openssl` over the owner proof's message, built here byte by byte, and converted from DER to the 64-byte r ‖ s;
// nothing in the window computes them. Used by live_owner_keys_test.dart and live_devices_test.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/host/touch_id.dart';

/// The published test key (CONTROL §22.5): its X9.62 point and its key ID.
const testPublicKey = 'BPcpOpocd8N5toWe1+F6lK+AU62/2qoTm5PZNlZIpsl9jTesqC2CuI6DrymmK5qk5RwfuiAXRDt0/imLMGqrz38=';
const testKeyId = '01b3e9c533123cb8';
final testKeyPem = File('test/fixtures/owner_test_key.pem').absolute.path;

bool hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<List<int>> openssl(List<String> args, List<int> input) async {
  final p = await Process.start('openssl', args);
  final out = BytesBuilder();
  final err = StringBuffer();
  final o = p.stdout.forEach(out.add);
  final e = p.stderr.transform(utf8.decoder).forEach(err.write);
  p.stdin.add(input);
  await p.stdin.close();
  final code = await p.exitCode;
  await o;
  await e;
  if (code != 0) throw StateError('openssl ${args.join(' ')}: $err');
  return out.takeBytes();
}

List<int> hexBytes(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

/// An ECDSA signature in DER (`SEQUENCE { INTEGER r, INTEGER s }`) as 64 bytes r ‖ s, each left-padded to 32.
Uint8List derToRaw(List<int> der) {
  var i = 0;
  int length() {
    final b = der[i++];
    if (b < 0x80) return b;
    var n = 0;
    for (var k = 0; k < (b & 0x7f); k++) {
      n = n << 8 | der[i++];
    }
    return n;
  }

  List<int> integer() {
    if (der[i++] != 0x02) throw const FormatException('not an INTEGER');
    final l = length();
    var v = der.sublist(i, i + l);
    i += l;
    while (v.length > 32 && v.first == 0) {
      v = v.sublist(1);
    }
    if (v.length > 32) throw const FormatException('integer too long');
    return [...List.filled(32 - v.length, 0), ...v];
  }

  if (der[i++] != 0x30) throw const FormatException('not a SEQUENCE');
  length();
  return Uint8List.fromList([...integer(), ...integer()]);
}

/// The proof's signature: ECDSA P-256 / SHA-256 over `"antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(request)`.
Future<String> softSign(String pem, String nonceHex, String request) async {
  final hash = await openssl(['dgst', '-sha256', '-binary'], utf8.encode(request));
  final message = [...utf8.encode('antenna/owner-proof/v1'), 0, ...hexBytes(nonceHex), ...hash];
  final der = await openssl(['dgst', '-sha256', '-sign', pem], message);
  return base64.encode(derToRaw(der));
}

/// The X9.62 point and the key ID (first 8 bytes of SHA-256 of the point) of a PEM private key.
Future<(String, String)> publicOf(String pem) async {
  final spki = await openssl(['pkey', '-in', pem, '-pubout', '-outform', 'DER'], const []);
  final point = spki.sublist(spki.length - 65);
  final id = (await openssl(['dgst', '-sha256', '-binary'], point)).sublist(0, 8);
  return (base64.encode(point), [for (final b in id) b.toRadixString(16).padLeft(2, '0')].join());
}

/// The Secure Enclave replaced by the test key in software: every "touch" is recorded; the slot key is kept in memory.
final class SoftwareTouchId implements TouchIdHost {
  final prompts = <(String, String, bool)>[];
  final signed = <String>[];
  String? _slot;
  OwnerKeyRecord? _record;
  bool _created = false;
  bool _reusable = false;

  @override
  bool get supported => true;

  @override
  String dirFor(String socketPath) => '/nonexistent/touchid/${touchIdFolderName(socketPath)}';

  @override
  Future<TouchIdStatus> status(String dir) async => TouchIdStatus(available: true, hpke: true, enrolled: _created);

  @override
  Future<TouchIdKeys> create(String dir) async {
    _created = true;
    return const TouchIdKeys(keyId: testKeyId, signingPublic: testPublicKey, agreementPublic: 'unused');
  }

  @override
  Future<String> sign({
    required String dir,
    required String nonce,
    required String request,
    required String reason,
    bool reuse = false,
  }) async {
    final reused = reuse && _reusable;
    _reusable = false;
    prompts.add(('sign', reason, reused));
    signed.add(request);
    return softSign(testKeyPem, nonce, request);
  }

  @override
  Future<void> seal({required String dir, required String slotKey}) async => _slot = slotKey;

  @override
  Future<String> openSlot({required String dir, required String reason}) async {
    prompts.add(('openSlot', reason, false));
    _reusable = true;
    return _slot ?? (throw const TouchIdException(TouchIdFailure.keyInvalidated));
  }

  @override
  Future<void> delete(String dir) async {
    _created = false;
    _slot = null;
    _record = null;
  }

  @override
  Future<OwnerKeyRecord?> readRecord(String dir) async => _record;

  @override
  Future<void> writeRecord(String dir, OwnerKeyRecord record) async => _record = record;
}
