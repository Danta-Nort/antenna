// SPDX-License-Identifier: AGPL-3.0-only
// Owner keys (x-control/7, CONTROL §22, D-102, experimental): the challenge for a proof, an enrolled key, the list.

part of 'models.dart';

/// `owner_challenge`: 32 random bytes as 64 hex, valid until [expiresMs], used once, for this client process only.
final class OwnerChallengeReply extends Reply {
  const OwnerChallengeReply({required this.nonce, required this.expiresMs, required this.passwordDueMs});

  factory OwnerChallengeReply.fromJson(Json j) => OwnerChallengeReply(
        nonce: _str(j, 'nonce'),
        expiresMs: _int(j, 'expires_ms'),
        passwordDueMs: _int(j, 'password_due_ms'),
      );

  final String nonce;
  final int expiresMs;

  /// After this moment proofs and unlock slots are refused (`password_required`) until the password is used once.
  final int passwordDueMs;
}

/// One enrolled owner key.
final class OwnerKeyInfo {
  const OwnerKeyInfo({
    required this.keyId,
    required this.label,
    required this.createdMs,
    this.lastUsedMs,
    this.unlock = false,
  });

  factory OwnerKeyInfo.fromJson(Json j) => OwnerKeyInfo(
        keyId: _str(j, 'key_id'),
        label: _optStr(j, 'label') ?? '',
        createdMs: _optInt(j, 'created_ms') ?? 0,
        lastUsedMs: _optInt(j, 'last_used_ms'),
        unlock: _bool(j, 'unlock'),
      );

  /// 16 hex: the first 8 bytes of SHA-256 of the 65-byte public key.
  final String keyId;
  final String label;
  final int createdMs;
  final int? lastUsedMs;

  /// The key also has an unlock slot.
  final bool unlock;
}

/// `owner_key_added`: the key as enrolled and, with `unlock`, the slot key, shown once. [slotKey] is a secret: it is
/// sealed to the Secure Enclave key and dropped, never stored or logged in the clear.
final class OwnerKeyAddedReply extends Reply {
  const OwnerKeyAddedReply({required this.key, this.slotKey});

  factory OwnerKeyAddedReply.fromJson(Json j) =>
      OwnerKeyAddedReply(key: OwnerKeyInfo.fromJson(_obj(j, 'key')), slotKey: _optStr(j, 'slot_key'));

  final OwnerKeyInfo key;

  /// Base64 of 32 bytes.
  final String? slotKey;

  @override
  String toString() => 'OwnerKeyAddedReply(${key.keyId}, slot key ${slotKey == null ? 'none' : '<redacted>'})';
}

/// `owner_keys`.
final class OwnerKeysReply extends Reply {
  const OwnerKeysReply({required this.keys, required this.passwordDueMs, this.testKey = false});

  factory OwnerKeysReply.fromJson(Json j) => OwnerKeysReply(
        keys: [for (final k in _list(j, 'keys')) OwnerKeyInfo.fromJson(k)],
        passwordDueMs: _optInt(j, 'password_due_ms') ?? 0,
        testKey: _bool(j, 'test_key'),
      );

  final List<OwnerKeyInfo> keys;
  final int passwordDueMs;

  /// A debug build started with `ANTENNA_OWNER_TEST_KEY=1` accepts the published test key (CONTROL §22.5).
  final bool testKey;
}
