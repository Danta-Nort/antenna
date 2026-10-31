// SPDX-License-Identifier: AGPL-3.0-only
// The owner confirms an owner command (D-102, D-131): with Touch ID on, one touch first, straight from the owner's
// click; the password when Touch ID is off, when the owner picks "Use password", and whenever the touch does not go
// through (cancelled, unavailable, the 14 days passed, three failed attempts, the key gone, fingerprints changed),
// saying why. A failure never becomes "allowed": the daemon checks every proof and every password (SPEC §9), and the
// window keeps neither (a proof is made per request over a fresh challenge and used once).
//
// Two shapes: [confirmOwner] for an action that used to open the password prompt (the Touch ID sheet opens instead,
// the prompt after it if needed), and [OwnerAuthField] with its [OwnerAuthController] for a form that had a password
// field (the field gives way to a line saying the form's button asks for a touch, with "Use password").

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/app_model.dart';
import '../../state/owner_auth.dart';
import '../../state/touch_id.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/dialog_shell.dart';
import 'touch_id_text.dart';

export 'touch_id_text.dart' show cutForPrompt;

/// The prompt's reason for an owner command described by [action] (a sentence the password prompt shows):
/// "confirm “Revoke the link with Bob”".
String touchIdConfirmReason(AppLocalizations l, String action) => l.touchIdReasonConfirm(cutForPrompt(action, 80));

/// Confirm one owner command. With Touch ID ready (and [touch], for a command the daemon takes a proof for), [run]
/// goes first with one touch, [reason] on the prompt (default: [action] in [touchIdConfirmReason]); when the touch
/// does not go through, the password prompt opens with [action], [detail] and [cli], saying why, and [run] goes again
/// with the password. Without Touch ID, the password prompt. [run] returns the command's error or `null`.
///
/// Returns `(true, null)` when it was done, `(false, null)` when the owner backed out, `(false, err)` when the daemon
/// refused it.
Future<(bool, Object?)> confirmOwner(
  BuildContext context, {
  required String action,
  String? detail,
  String? cli,
  String? reason,
  bool touch = true,
  required Future<Object?> Function(OwnerAuth auth) run,
}) async {
  final m = AppScope.read(context);
  final l = context.l;
  String? note;
  if (touch && m.touchIdReady) {
    final err = await run(TouchAuth(reason ?? touchIdConfirmReason(l, action)));
    if (err == null) return (true, null);
    if (TouchIdMixin.fallbackFor(err) == TouchIdFallback.none) return (false, err);
    note = touchIdFallbackNote(l, m, err);
    if (!context.mounted) return (false, null);
  }
  final pw = await askOwnerPassword(context, action: action, detail: detail, cli: cli, note: note);
  if (pw == null || !context.mounted) return (false, null);
  final err = await run(PasswordAuth(pw));
  return (err == null, err);
}

/// Approve request [id] held for the owner (a secret in a message or a file being sent): one touch over the request
/// and its fingerprint when Touch ID is on and the window knows the request (D-102), the password otherwise or when the
/// touch does not go through. Returns as [confirmOwner] does.
Future<(bool, Object?)> confirmApproval(
  BuildContext context,
  String id, {
  required String action,
  String? detail,
  String? cli,
}) {
  final m = AppScope.read(context);
  final a = m.approvals[id];
  return confirmOwner(
    context,
    action: action,
    detail: detail,
    cli: cli,
    touch: a != null,
    reason: a == null ? null : touchIdApproveReason(context.l, a),
    run: (auth) => switch (auth) {
      TouchAuth(:final reason) => m.approveWithTouchId(a!, reason: reason),
      PasswordAuth(:final password) => m.approve(id, password),
    },
  );
}

/// The owner's confirmation inside a form: one touch when Touch ID is ready, otherwise (or after "Use password", or
/// after a touch that did not go through) the password in [password].
final class OwnerAuthController extends ChangeNotifier {
  /// The password field's text.
  final password = TextEditingController();

  bool _usePassword = false;
  String? _note;

  /// Why the password is asked although Touch ID is on (shown above the field), or `null`.
  String? get note => _note;

  /// The form's button asks for a touch, not the password.
  bool usesTouch(AppModel m) => m.touchIdReady && !_usePassword;

  /// The form can be sent: a touch, or a password typed.
  bool ready(AppModel m) => usesTouch(m) || password.text.isNotEmpty;

  /// The confirmation for the form's command; [reason] is the Touch ID prompt's text.
  OwnerAuth auth(AppModel m, String reason) => usesTouch(m) ? TouchAuth(reason) : PasswordAuth(password.text);

  /// The owner picked "Use password".
  void usePassword() {
    _usePassword = true;
    notifyListeners();
  }

  /// The command came back with [err]: when it is a Touch ID matter, the form switches to the password, saying why,
  /// and this returns `true` (the form shows no error then).
  bool fellBack(AppLocalizations l, AppModel m, Object? err) {
    if (err == null || TouchIdMixin.fallbackFor(err) == TouchIdFallback.none) return false;
    _usePassword = true;
    _note = touchIdFallbackNote(l, m, err);
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }
}

/// In a form: with Touch ID ready, a line that says the form's button asks for a touch and "Use password"; otherwise
/// the owner password field (with the reason above it when Touch ID could not do it).
class OwnerAuthField extends StatelessWidget {
  const OwnerAuthField({super.key, required this.controller, this.onSubmitted, this.autofocus = false});
  final OwnerAuthController controller;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.usesTouch(m)) {
          return Row(key: const Key('owner-touch'), children: [
            Icon(Icons.fingerprint, size: 18, color: XColors.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(l.ownerTouchIdLine, style: XText.bodyDim)),
            TextButton(
              key: const Key('owner-use-password'),
              onPressed: controller.usePassword,
              child: Text(l.approvalsUsePassword),
            ),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (controller.note case final note?) ...[
            Row(key: const Key('password-note'), crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.fingerprint, size: 16, color: XColors.textDim),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(note, style: XText.bodyDim)),
            ]),
            const SizedBox(height: 12),
          ],
          OwnerPasswordField(
            controller: controller.password,
            onSubmitted: onSubmitted,
            autofocus: autofocus || controller.note != null || controller._usePassword,
          ),
        ]);
      },
    );
  }
}
