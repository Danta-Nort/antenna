// SPDX-License-Identifier: AGPL-3.0-only
// Client errors of the antenna_proto::control protocol. Pure Dart, no Flutter.

/// Daemon error codes (`antenna_proto::control::code`). An unknown code is kept as is.
abstract final class XErrorCode {
  static const badRequest = 'bad_request';
  static const notInitialized = 'not_initialized';
  static const alreadyInitialized = 'already_initialized';
  static const locked = 'locked';
  static const wrongPassword = 'wrong_password';
  static const forbidden = 'forbidden';
  static const notFound = 'not_found';
  static const pairingFailed = 'pairing_failed';
  static const sasMismatch = 'sas_mismatch';
  static const rejected = 'rejected';
  static const inviteUnavailable = 'invite_unavailable';
  static const network = 'network';
  static const timeout = 'timeout';
  static const notImplemented = 'not_implemented';
  static const internal = 'internal';
  // x-control/1
  static const unknownCommand = 'unknown_command';
  static const tokenInvalid = 'token_invalid';
  static const tokenBound = 'token_bound';
  static const approvalRequired = 'approval_required';
  static const denied = 'denied';
  static const rateLimited = 'rate_limited';
  static const approvalUsed = 'approval_used';
  static const approvalExpired = 'approval_expired';
  static const approvalMismatch = 'approval_mismatch';
  static const approvalDenied = 'approval_denied';
  static const approvalPending = 'approval_pending';
  // x-control/2
  static const loginRequired = 'login_required';
  static const rekeyRequired = 'rekey_required';
  static const readOnly = 'read_only';
  static const recovering = 'recovering';
  static const historyConflict = 'history_conflict';
  static const badSignature = 'bad_signature';
  // x-control/4
  static const sandboxUnavailable = 'sandbox_unavailable';
  // x-control/6 (D-95)
  /// A pairing confirmation without the code was refused: another invite of this node showed a code at the same
  /// time, so a spoken "it matches" does not name the invite (formal model F-4); the owner types the code.
  static const codeRequired = 'code_required';
  // x-control/7 (D-103)
  /// `update_auto_set`: this installation cannot replace itself (a development build, the Linux window bundle).
  static const unsupportedInstall = 'unsupported_install';

  /// `update_auto_now` / `update_auto_later` while an automatic install runs.
  static const updateInProgress = 'update_in_progress';

  /// `file_accept`: another file has this name in the folder (CONTROL §14).
  static const fileNameTaken = 'file_name_taken';

  /// `file_accept`: the name breaks the naming rules.
  static const badFileName = 'bad_file_name';

  // x-control/7 (CONTROL §22, D-102): owner keys and proofs
  /// The proof's challenge was not issued to this client, has expired (60 s) or was already used.
  static const challengeInvalid = 'challenge_invalid';

  /// The signature does not hold for this request and challenge.
  static const proofInvalid = 'proof_invalid';

  /// No such owner key (removed, or never enrolled on this node); also an unlock by a slot this key does not have.
  static const ownerKeyUnknown = 'owner_key_unknown';

  /// This build refuses the key (the published test key outside a debug build started for tests).
  static const ownerKeyRefused = 'owner_key_refused';

  /// The password is needed this time: 14 days since it was last used, or three failed proofs in a row.
  static const passwordRequired = 'password_required';

  /// The unlock slot did not open with this key, or the slot was changed.
  static const slotInvalid = 'slot_invalid';

  // x-control/7 (CONTROL §24): local models
  /// Not enough free disk space for a model: the message says how much is needed and how much is free.
  static const noSpace = 'no_space';

  /// A model file did not match the size and SHA-256 of this release; it was deleted.
  static const hashMismatch = 'hash_mismatch';

  /// A model download failed (the network, the host, or the file is gone); it resumes on the next try.
  static const fetchFailed = 'fetch_failed';

  /// This build has no local model runtime, or this computer cannot run one.
  static const runtimeUnavailable = 'runtime_unavailable';

  // x-control/7 (CONTROL §25): teams of agents
  /// Nothing in the team's budget, the template or this computer's limits fits: the message says why.
  static const noCapacity = 'no_capacity';

  /// The task's state does not allow it: the message says what it needs.
  static const taskState = 'task_state';

  /// A result does not merge into the team's branch: nothing changed; the message names the files.
  static const mergeConflict = 'merge_conflict';

  // x-control/7 (CONTROL §28): profile pictures
  /// `picture_set {photo}`: the file is not an image the daemon can read, is too large, or did not pass the image
  /// check in its sandbox.
  static const pictureRefused = 'picture_refused';

  // 0.2.0 (CONTROL §10): a message's text is over 64 KiB of UTF-8; send it as a file. An older daemon says
  // `bad_request` for it.
  static const textTooLong = 'text_too_long';
}

/// Base class of client errors.
sealed class XClientException implements Exception {
  const XClientException(this.message);

  /// Human-readable description (in English, as sent by the daemon or produced by the socket).
  final String message;
}

/// The daemon replied `{"err":{code,message}}`.
final class XControlException extends XClientException {
  const XControlException(this.code, String message, {this.approval}) : super(message);

  /// Machine-readable code (see [XErrorCode]).
  final String code;

  /// For `approval_required`: the approval request that was created (or is already pending), as `ApprovalInfo` JSON.
  final Map<String, Object?>? approval;

  @override
  String toString() => 'XControlException($code: $message)';
}

/// The daemon is unreachable: no socket, the connection was refused, or it dropped before a reply.
final class XDaemonUnreachable extends XClientException {
  const XDaemonUnreachable(this.socketPath, String message) : super(message);

  /// The socket path the client tried to connect to.
  final String socketPath;

  @override
  String toString() => 'XDaemonUnreachable($socketPath: $message)';
}

/// The daemon's endpoint is held by a process the client does not trust: another user's, or one it could not check
/// (`daemon_untrusted` from the CLI on Windows, D-135 item 4). Deliberately not [XDaemonUnreachable]: the window must
/// not start a second daemon against whatever holds the endpoint.
final class XDaemonUntrusted extends XClientException {
  const XDaemonUntrusted(this.socketPath, String message) : super(message);

  /// The socket path the client was configured with (on Windows the bridge resolves the pipe itself).
  final String socketPath;

  @override
  String toString() => 'XDaemonUntrusted($socketPath: $message)';
}

/// Protocol violation: not JSON, unexpected message order, a line that is too long.
final class XProtocolException extends XClientException {
  const XProtocolException(super.message);

  @override
  String toString() => 'XProtocolException($message)';
}

/// No owner proof was made for a request (v7, D-131): the prover failed before anything went to the daemon (the owner
/// cancelled the Touch ID prompt, Touch ID is unavailable, the key cannot be used). [cause] is the prover's error; the
/// screen asks for the password instead.
final class XProofException extends XClientException {
  XProofException(this.cause) : super('no owner proof: $cause');

  /// What the prover threw.
  final Object cause;

  @override
  String toString() => 'XProofException($cause)';
}
