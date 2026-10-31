// SPDX-License-Identifier: AGPL-3.0-only
// The owner keys of the fake daemon (x-control/7, CONTROL §22): challenges, enrolled keys, unlock slots and the check of
// a proof, in the order of CONTROL §22.2. The fake's "signature" is not cryptography: [fakeSig] names the key, the
// challenge and the exact request text, so a test sees that the window signed what it sent, with the challenge it was
// given. The real signature (ECDSA P-256 over the message of §22.2) is checked by the live test against antennad.

import 'dart:convert';

import 'package:antenna_desktop/protocol/x_control.dart';

/// The fake key ID of a public key (the daemon's is the first 8 bytes of SHA-256 of the 65-byte point).
String fakeKeyId(String publicKey) {
  final b = utf8.encode(publicKey);
  var x = 0x2545f491;
  for (final c in b) {
    x = (x * 31 + c) & 0x7fffffff;
  }
  return x.toRadixString(16).padLeft(8, '0') * 2;
}

/// What the fake Secure Enclave "signs": the key, the challenge and the request text.
String fakeSig(String publicKey, String nonce, String request) =>
    base64.encode(utf8.encode('sig:${fakeKeyId(publicKey)}:$nonce:$request'));

/// One enrolled key.
final class FakeOwnerKey {
  FakeOwnerKey({required this.publicKey, required this.label, required this.unlock, this.slotKey});
  final String publicKey;
  final String label;
  final bool unlock;
  final String? slotKey;
  int? lastUsedMs;

  String get keyId => fakeKeyId(publicKey);
}

final class FakeOwnerKeys {
  /// Enrolled keys by ID.
  final keys = <String, FakeOwnerKey>{};

  /// Challenges issued and not used yet.
  final outstanding = <String>{};

  /// `enroll` of every challenge asked, in order.
  final challengeKinds = <bool>[];

  /// The outstanding challenges issued with `enroll: true`: good only for `owner_key_add`, which takes only those.
  final enrollNonces = <String>{};

  /// Every line with a proof, as the window sent it: the request text and the proof.
  final lines = <(String, OwnerProof)>[];

  /// When the password is due again (14 days after the last one).
  int passwordDueMs = DateTime(2026, 10, 16, 14, 32).millisecondsSinceEpoch;

  /// Proofs and slots are refused until the password is used: 14 days passed, or three failed proofs.
  bool needPassword = false;
  int failedProofs = 0;
  int _seq = 0;

  /// [enroll]: issued even when other proofs wait for the password (CONTROL §22.2).
  OwnerChallengeReply challenge({bool enroll = false}) {
    challengeKinds.add(enroll);
    if (!enroll && (needPassword || failedProofs >= 3)) {
      throw const XControlException(XErrorCode.passwordRequired, 'the owner password is needed this time');
    }
    final n = (++_seq).toRadixString(16).padLeft(64, 'c');
    outstanding.add(n);
    if (enroll) enrollNonces.add(n);
    return OwnerChallengeReply(nonce: n, expiresMs: 0, passwordDueMs: passwordDueMs);
  }

  /// The checks of CONTROL §22.2 in their order. [enrolling] is the public key `owner_key_add` enrolls: its proof must
  /// be by that key.
  void verify(String req, OwnerProof proof, {String? enrolling}) {
    lines.add((req, proof));
    final forEnroll = enrollNonces.remove(proof.nonce);
    // An enroll challenge is issued while the password is due, but only owner_key_add's proof gets past this then.
    if (enrolling == null && (needPassword || failedProofs >= 3)) {
      outstanding.remove(proof.nonce);
      throw const XControlException(XErrorCode.passwordRequired, 'the owner password is needed this time');
    }
    // A challenge serves its purpose only: an enroll challenge for owner_key_add, a plain one for everything else.
    if (!outstanding.remove(proof.nonce) || forEnroll != (enrolling != null)) {
      failedProofs++;
      throw const XControlException(XErrorCode.challengeInvalid, 'unknown, expired, used or another kind of challenge');
    }
    final publicKey = enrolling ?? keys[proof.keyId]?.publicKey;
    if (publicKey == null || fakeKeyId(publicKey) != proof.keyId) {
      failedProofs++;
      throw const XControlException(XErrorCode.ownerKeyUnknown, 'no such owner key');
    }
    if (proof.sig != fakeSig(publicKey, proof.nonce, req)) {
      failedProofs++;
      throw const XControlException(XErrorCode.proofInvalid, 'the proof does not verify');
    }
    failedProofs = 0;
    keys[proof.keyId]?.lastUsedMs = 1;
  }

  OwnerKeyAddedReply add(String publicKey, String label, {required bool unlock}) {
    final slot = unlock ? base64.encode(List<int>.generate(32, (i) => (i * 7 + keys.length) & 0xff)) : null;
    final k = FakeOwnerKey(publicKey: publicKey, label: label, unlock: unlock, slotKey: slot);
    keys[k.keyId] = k;
    return OwnerKeyAddedReply(key: info(k), slotKey: slot);
  }

  OwnerKeyInfo info(FakeOwnerKey k) =>
      OwnerKeyInfo(keyId: k.keyId, label: k.label, createdMs: 0, lastUsedMs: k.lastUsedMs, unlock: k.unlock);

  OwnerKeysReply list() => OwnerKeysReply(keys: [for (final k in keys.values) info(k)], passwordDueMs: passwordDueMs);

  void remove(String keyId) {
    if (keys.remove(keyId) == null) throw const XControlException(XErrorCode.notFound, 'no such owner key');
  }

  void openSlot(String keyId, String slotKey) {
    if (needPassword) throw const XControlException(XErrorCode.passwordRequired, 'the owner password is needed');
    final k = keys[keyId];
    if (k == null || k.slotKey == null) throw const XControlException(XErrorCode.ownerKeyUnknown, 'no slot');
    if (k.slotKey != slotKey) throw const XControlException(XErrorCode.slotInvalid, 'the slot does not open');
  }

  /// A correct password resets the proof counter and the 14 days.
  void passwordUsed() {
    failedProofs = 0;
    needPassword = false;
  }
}
