// SPDX-License-Identifier: AGPL-3.0-only
// The words of Touch ID (D-102): the reason each prompt shows (macOS writes "“Antenna” is trying to <reason>.", so a
// reason is a verb phrase that names exactly what one touch approves), and the line a password prompt shows when Touch
// ID could not do it this time. Names that come from agents or contacts are cut and stripped of control characters:
// the prompt is the system's, and a long or odd name must not crowd out what is being approved.

import 'package:flutter/widgets.dart' show StringCharacters;

import '../../host/touch_id.dart';
import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/touch_id.dart';
import '../approvals/approval_card.dart' show actionLabel;

/// [s] on one line, at most [max] characters (an ellipsis when cut).
String cutForPrompt(String s, [int max = 32]) {
  final one = s.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f  ]+'), ' ').trim();
  final c = one.characters;
  return c.length <= max ? one : '${c.take(max - 1)}…';
}

/// The prompt's reason for one approval: the action and whom it concerns ("approve sending a message to Bob").
String touchIdApproveReason(AppLocalizations l, ApprovalInfo a) {
  final target = cutForPrompt(a.target ?? a.contact);
  return switch (a.action) {
    'send_message' => l.touchIdReasonSend(target),
    'share_file' => l.touchIdReasonShareFile(target),
    'request_file' => l.touchIdReasonRequestFile(target),
    'accept_file' => l.touchIdReasonAcceptFile(cutForPrompt(a.contact)),
    _ => l.touchIdReasonOther(cutForPrompt(actionLabel(l, a.action)), cutForPrompt(a.requester)),
  };
}

/// The prompt's reason for a listed batch: how many and from whom ("approve 3 requests from claude").
String touchIdBatchReason(AppLocalizations l, List<ApprovalInfo> items) {
  final who = <String>[];
  for (final a in items) {
    if (!who.contains(a.requester)) who.add(a.requester);
  }
  final shown = who.length <= 2 ? who.join(', ') : '${who.take(2).join(', ')}, …';
  return l.touchIdReasonMany(items.length, cutForPrompt(shown, 48));
}

/// The line above the password field when Touch ID could not do it this time; `null` when there is nothing to add
/// (the owner cancelled the prompt) or [err] is not about Touch ID.
String? touchIdFallbackNote(AppLocalizations l, AppModel m, Object? err) => switch (TouchIdMixin.fallbackFor(err)) {
      TouchIdFallback.none || TouchIdFallback.cancelled => null,
      TouchIdFallback.unavailable =>
        err is TouchIdException && err.reason == TouchIdFailure.lockout ? l.touchIdNoteLockout : l.touchIdNoteUnavailable,
      TouchIdFallback.fingerprintsChanged => l.touchIdNoteFingerprints,
      TouchIdFallback.keyGone => l.touchIdNoteKeyGone,
      TouchIdFallback.slotInvalid => l.touchIdNoteSlot,
      TouchIdFallback.passwordRequired => switch (m.passwordReason()) {
          PasswordReason.due => l.touchIdNoteDue,
          PasswordReason.failedAttempts => l.touchIdNoteFailed,
          PasswordReason.unknown => l.touchIdNoteRequired,
        },
    };
