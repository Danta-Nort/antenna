// SPDX-License-Identifier: AGPL-3.0-only
// Human-readable daemon errors in the window's language. The error code comes from the protocol; the daemon's
// (English) text goes into the hint.

import '../host/touch_id.dart';
import '../l10n/app_localizations.dart';
import '../protocol/x_control.dart';

/// A short explanation of the error for the owner.
String describeError(AppLocalizations l, Object e) {
  return switch (e) {
    XControlException(code: XErrorCode.wrongPassword) => l.errWrongPassword,
    XControlException(code: XErrorCode.locked) => l.errLocked,
    XControlException(code: XErrorCode.notInitialized) => l.errNotInitialized,
    XControlException(code: XErrorCode.alreadyInitialized) => l.errAlreadyInitialized,
    XControlException(code: XErrorCode.sasMismatch) => l.errSasMismatch,
    XControlException(code: XErrorCode.rejected) => l.errRejected,
    XControlException(code: XErrorCode.inviteUnavailable) => l.errInviteUnavailable,
    XControlException(code: XErrorCode.pairingFailed) => l.errPairingFailed,
    XControlException(code: XErrorCode.notFound) => l.errNotFound,
    XControlException(code: XErrorCode.network) => l.errNetwork,
    XControlException(code: XErrorCode.timeout) => l.errTimeout,
    XControlException(code: XErrorCode.forbidden) => l.errForbidden,
    XControlException(code: XErrorCode.notImplemented) => l.errNotImplemented,
    XControlException(code: XErrorCode.rateLimited) => l.errRateLimited,
    XControlException(code: XErrorCode.approvalRequired) => l.errApprovalRequired,
    XControlException(code: XErrorCode.denied) => l.errDenied,
    XControlException(code: XErrorCode.approvalExpired) => l.errApprovalExpired,
    XControlException(code: XErrorCode.approvalUsed) => l.errApprovalUsed,
    XControlException(code: XErrorCode.approvalDenied) => l.errApprovalDenied,
    XControlException(code: XErrorCode.approvalMismatch) => l.errApprovalMismatch,
    XControlException(code: XErrorCode.unknownCommand) => l.errUnknownCommand,
    XControlException(code: XErrorCode.loginRequired) => l.errLoginRequired,
    XControlException(code: XErrorCode.rekeyRequired) => l.errRekeyRequired,
    XControlException(code: XErrorCode.readOnly) => l.errReadOnly,
    XControlException(code: XErrorCode.recovering) => l.errRecovering,
    XControlException(code: XErrorCode.historyConflict) => l.errHistoryConflict,
    XControlException(code: XErrorCode.badSignature) => l.errBadSignature,
    XControlException(code: XErrorCode.challengeInvalid) => l.errChallengeInvalid,
    XControlException(code: XErrorCode.proofInvalid) => l.errProofInvalid,
    XControlException(code: XErrorCode.ownerKeyUnknown) => l.errOwnerKeyUnknown,
    XControlException(code: XErrorCode.ownerKeyRefused) => l.errOwnerKeyRefused,
    XControlException(code: XErrorCode.passwordRequired) => l.errPasswordRequired,
    XControlException(code: XErrorCode.slotInvalid) => l.errSlotInvalid,
    XControlException(code: XErrorCode.badRequest, :final message) => l.errBadRequest(message),
    XControlException(:final code, :final message) => '$code: $message',
    XDaemonUnreachable() => l.errDaemonUnreachable,
    XDaemonUntrusted() => l.errDaemonUntrusted,
    XProtocolException(:final message) => l.errProtocol(message),
    TouchIdException(:final reason) => describeTouchId(l, reason),
    XProofException(:final cause) => describeError(l, cause),
    _ => e.toString(),
  };
}

/// A Touch ID step that did not happen, in words (D-102).
String describeTouchId(AppLocalizations l, TouchIdFailure reason) => switch (reason) {
      TouchIdFailure.cancelled => l.touchIdErrCancelled,
      TouchIdFailure.unavailable => l.touchIdErrUnavailable,
      TouchIdFailure.lockout => l.touchIdErrLockout,
      TouchIdFailure.keyInvalidated => l.touchIdErrInvalidated,
      TouchIdFailure.notEnrolled => l.touchIdErrNotEnrolled,
      TouchIdFailure.failed => l.touchIdErrFailed,
    };

/// Technical details (the daemon's English text) for the hint under the error.
String? errorDetail(Object e) => switch (e) {
      XControlException(:final code, :final message) => '$code · $message',
      XDaemonUnreachable(:final socketPath, :final message) => '$socketPath · $message',
      XDaemonUntrusted(:final socketPath, :final message) => '$socketPath · $message',
      TouchIdException(:final reason, :final detail) when detail.isNotEmpty => 'touch_id ${reason.name} · $detail',
      XProofException(:final cause) => errorDetail(cause),
      _ => null,
    };

/// Invite confirmation error on A (the owner enters the code).
String describeConfirmError(AppLocalizations l, Object e) => switch (e) {
      XControlException(code: XErrorCode.sasMismatch) => l.errConfirmNotThisCode,
      XControlException(code: XErrorCode.badRequest) => l.errConfirmEnterCode,
      XControlException(code: XErrorCode.codeRequired) => l.pairCodeRequired,
      XControlException(code: XErrorCode.wrongPassword) => l.errWrongOwnerPassword,
      XControlException(code: XErrorCode.rateLimited) => l.errTooManyPasswords,
      _ => describeError(l, e),
    };

/// Error of a rekey step.
String describeRekeyError(AppLocalizations l, Object e) => switch (e) {
      XControlException(code: XErrorCode.sasMismatch) => l.errRekeyWrongCode,
      XControlException(code: XErrorCode.notFound) => l.errRekeyNoProposal,
      XControlException(code: XErrorCode.recovering, :final message) => l.errRekeyRecovering(message),
      XControlException(code: XErrorCode.pairingFailed) => l.errRekeyTwoProposals,
      XControlException(code: XErrorCode.badRequest, :final message) => l.errRekeyBadStep(message),
      XControlException(code: XErrorCode.wrongPassword) => l.errWrongOwnerPassword,
      _ => describeError(l, e),
    };
