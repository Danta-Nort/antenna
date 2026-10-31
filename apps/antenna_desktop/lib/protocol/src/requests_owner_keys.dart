// SPDX-License-Identifier: AGPL-3.0-only
// Owner keys (x-control/7, CONTROL §22, D-102, experimental): a part of requests.dart. A key the owner enrolled with
// the password signs one command (or one listed batch) in place of the password: the daemon issues a one-time
// challenge, the key signs the challenge and the exact bytes of the request, and the proof rides on the request's own
// line. The daemon verifies every proof itself (SPEC §9); the client only carries it.

part of 'requests.dart';

/// A one-time challenge for a proof (no owner session; the keys must be unlocked). `password_required` when proofs
/// would be refused anyway (14 days since the last password, or three failed proofs): ask for the password before a
/// Touch ID prompt. [enroll]: a challenge for `owner_key_add`'s proof of possession only, issued even then (that
/// request carries the password); the daemon refuses any other proof made with it.
final class OwnerChallengeRequest extends XRequest {
  const OwnerChallengeRequest({this.enroll = false});
  final bool enroll;
  @override
  String get cmd => 'owner_challenge';
  @override
  Json get fields => {if (enroll) 'enroll': true};
}

/// Enroll an owner key: the owner [password] and, on the same line, a proof by this new key (proof of possession;
/// never a proof by another key). [publicKey] is base64 of the 65-byte X9.62 uncompressed P-256 point. With
/// [unlock], the daemon also creates an unlock slot and returns its key once (`owner_key_added.slot_key`).
final class OwnerKeyAddRequest extends XRequest {
  const OwnerKeyAddRequest({required this.publicKey, required this.label, required this.password, this.unlock = false});
  final String publicKey;

  /// 1–64 bytes, no control characters.
  final String label;
  final bool unlock;
  final String password;
  @override
  String get cmd => 'owner_key_add';
  @override
  Json get fields => {'public_key': publicKey, 'label': label, 'unlock': unlock, 'password': password};
}

/// The enrolled owner keys, when the password is due, and whether this build accepts the test key (owner session).
final class OwnerKeyListRequest extends XRequest {
  const OwnerKeyListRequest();
  @override
  String get cmd => 'owner_key_list';
  @override
  Json get fields => const {};
}

/// Remove an owner key and its unlock slot. No password and no session (D-84): it only takes a way in away.
final class OwnerKeyRemoveRequest extends XRequest {
  const OwnerKeyRemoveRequest(this.keyId);
  final String keyId;
  @override
  String get cmd => 'owner_key_remove';
  @override
  Json get fields => {'key_id': keyId};
}

/// A proof: which key signed, the challenge it signed, and the signature (base64 of the 64-byte `r ‖ s`).
final class OwnerProof {
  const OwnerProof({required this.keyId, required this.nonce, required this.sig});

  /// 16 hex: the first 8 bytes of SHA-256 of the 65-byte public key.
  final String keyId;

  /// 64 hex: the daemon's challenge (one use, 60 s, this client process only).
  final String nonce;
  final String sig;

  Json toJson() => {'key_id': keyId, 'nonce': nonce, 'sig': sig};

  @override
  String toString() => 'OwnerProof($keyId, sig <redacted>)';
}

/// Makes the proof for one request: gets the exact text of the request as it goes on the line (the bytes the daemon
/// hashes) and signs `"antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(text)`.
typedef ProofSource = Future<OwnerProof> Function(String request);

/// The text of [request] as it goes on the line. A proof signs exactly this text, so it is computed once and the line
/// carries it unchanged ([proofLine]).
String requestText(XRequest request) => jsonEncode(request.toJson());

/// The line of a request with a proof: `{"req":<req>,"proof":{…}}`, the only two keys. [req] is written as is, never
/// re-encoded: the daemon hashes the bytes of the `req` value it parses (CONTROL §22.2), so a re-encoding with another
/// key order or escaping would not verify.
String proofLine(String req, OwnerProof proof) => '{"req":$req,"proof":${jsonEncode(proof.toJson())}}';
