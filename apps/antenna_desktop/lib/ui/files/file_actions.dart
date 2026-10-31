// SPDX-License-Identifier: AGPL-3.0-only
// File decisions (owner): preview, accept, reject; attaching by file picker (the composer sends on Send). The daemon
// enforces the rules: it accepts a threat or an unchecked file only with `force` and the owner password, and a special
// name (dotfile, auto-executable) only with a separate permission.

import 'dart:async';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';

import '../../host/outgoing_staging.dart';
import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/files.dart';
import '../../state/messages.dart';
import '../../state/owner_auth.dart';
import '../../state/touch_id.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../security/touch_id_text.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';
import 'preview_dialog.dart';
import 'rename_dialog.dart';

/// File choice through the system dialog. Replaced in tests (`flutter test` has no plugins).
abstract class FileChooser {
  /// [confirm] is the label of the system dialog's button.
  Future<String?> pick(String confirm);

  static FileChooser instance = _SystemChooser();
}

class _SystemChooser implements FileChooser {
  @override
  Future<String?> pick(String confirm) async => (await fs.openFile(confirmButtonText: confirm))?.path;
}

/// A file error in plain words.
String describeFileError(AppLocalizations l, Object? e) => switch (e) {
      XControlException(code: 'file_quota_exceeded') => l.filesErrQuota,
      XControlException(code: XErrorCode.badFileName) => l.filesErrBadName,
      XControlException(code: XErrorCode.fileNameTaken) => l.filesErrNameTaken,
      XControlException(code: 'level_forbids_files') => l.filesErrLevel,
      XControlException(code: 'denied') => l.filesErrDenied,
      XControlException(code: 'transfer_failed') => l.filesErrTransfer,
      XControlException(code: 'not_found') => l.filesErrNotFound,
      null => l.filesErrUnknown,
      final Object o => describeError(l, o),
    };

/// What a file the own-computer rules hold is (D-130), worded like a browser's download warning: the danger in
/// plain words, never a refusal. Only for [FileHeld.holdsByRule].
String heldWarningText(AppLocalizations l, FileInfo f) => switch (f.held?.code) {
      'executable' => f.mime == null ? l.filesHeldExecutableNoMime : l.filesHeldExecutable(f.mime!),
      'installer' => l.filesHeldInstaller,
      'uninspected' => l.filesHeldUninspected,
      'threat' => l.filesHeldThreat,
      _ => l.filesHeldCheckFailed,
    };

/// Attach a file to the selected link's composer through the system file picker (copied when small, like a drop).
Future<void> pickAndAttach(BuildContext context) async {
  final m = AppScope.read(context);
  final c = m.selected;
  if (c == null) return;
  final path = await FileChooser.instance.pick(context.l.filesChooserSend);
  if (path == null) return;
  final staging = OutgoingStaging.instance;
  m.stageAttachment(c.linkId, staging == null ? StagedFile(path) : await staging.stageFile(path));
}

/// A secret in a file waiting in the composer: the owner approves (password), then that file is sent with
/// `approval_id`. The caption stays in the field for the next Send.
Future<void> approveStaged(BuildContext context, String linkId, StagedAttachment a) async {
  final m = AppScope.read(context);
  final l = context.l;
  final id = a.approvalId!;
  final (done, err) = await confirmApproval(context, id,
      action: l.filesApproveAction(a.name), detail: l.filesApproveDetail, cli: 'antenna approve $id');
  if (!done) {
    if (err != null && context.mounted) _snack(context, describeError(l, err));
    return;
  }
  await m.sendStaged(linkId, only: a);
}

/// A secret in the file being sent: the owner approves (password) and sends with `approval_id`.
Future<void> approveAndShare(BuildContext context, OutgoingFile o) async {
  final m = AppScope.read(context);
  final l = context.l;
  final id = o.approvalId!;
  final (done, err) = await confirmApproval(context, id,
      action: l.filesApproveAction(o.name), detail: l.filesApproveDetail, cli: 'antenna approve $id');
  if (!done) {
    if (err != null && context.mounted) _snack(context, describeError(l, err));
    return;
  }
  await m.shareFile(o.linkId, o.path, approvalId: id, retry: o);
}

/// Accept: the normal path; a threat or unchecked file needs `force` with the password; a special name needs a
/// separate permission. A name taken by another file asks nothing: the daemon saves the file under the next free
/// number (`report (2).pdf`, D-128) and the card says "Saved as …"; the same file under the name is accepted without
/// a copy (preview.8: `duplicate`). "Another name" (rename_dialog.dart: it checks names as they are typed and shows
/// every refusal) opens only for a name the daemon cannot use (`bad_file_name`), and for `file_name_taken` from a
/// daemon older than D-128 or one whose every numbered name is taken. [keep]: Keep anyway on a file the own-computer
/// rules hold (D-130): always the password and `force`, which the daemon requires for such a file.
Future<void> acceptFileFlow(BuildContext context, FileInfo f, {required int level, bool keep = false}) async {
  final m = AppScope.read(context);
  final l = context.l;
  final force = keep || f.needsForce;
  final action =
      keep ? l.filesKeepAction(f.name) : (f.verdict == 'threat' ? l.filesForceThreatAction : l.filesForceFailedAction);
  final detail = keep ? heldWarningText(l, f) : l.filesForceDetail;
  final cli = 'antenna files accept ${f.id.substring(0, 8)} --force';
  // Forcing takes the owner: one touch when Touch ID is on (D-131), otherwise the password.
  OwnerAuth? auth;
  if (force && m.touchIdReady) {
    auth = TouchAuth(touchIdConfirmReason(l, action));
  } else if (force) {
    final pw = await askOwnerPassword(context, action: action, detail: detail, cli: cli);
    if (pw == null) return;
    auth = PasswordAuth(pw);
  }
  var allowSpecial = false;
  // One accept under [name]: the daemon's error, `null`, or [AcceptDeclined] when the owner declined the special-name
  // question.
  Future<Object?> accept(String? name) async {
    while (true) {
      final err = await m.acceptFile(f.id, name: name, force: force, allowSpecial: allowSpecial, auth: auth);
      if (err is XControlException && err.code == XErrorCode.approvalRequired && !allowSpecial && context.mounted) {
        if (await _confirmSpecial(context, f) != true) return const AcceptDeclined();
        allowSpecial = true;
        continue;
      }
      return err;
    }
  }

  var err = await accept(null);
  // A touch that did not go through: the password, saying why, then once more.
  if (auth is TouchAuth && TouchIdMixin.fallbackFor(err) != TouchIdFallback.none && context.mounted) {
    final pw =
        await askOwnerPassword(context, action: action, detail: detail, cli: cli, note: touchIdFallbackNote(l, m, err));
    if (pw == null) return;
    auth = PasswordAuth(pw);
    err = await accept(null);
  }
  if (err == null || err is AcceptDeclined || !context.mounted) return;
  if (err is XControlException && (err.code == XErrorCode.fileNameTaken || err.code == XErrorCode.badFileName)) {
    await showFileRenameDialog(context, f, refused: err, accept: accept);
    return;
  }
  _snack(context, l.filesNotAccepted(describeFileError(l, err)));
}

/// Withdraw a sent file the contact has not answered (preview.5). The card shows the result; an error is said once.
Future<void> withdrawFileFlow(BuildContext context, FileInfo f) async {
  final l = context.l;
  final err = await AppScope.read(context).withdrawFile(f);
  if (err == null || !context.mounted) return;
  _snack(
      context,
      switch (err) {
        XControlException(code: XErrorCode.unknownCommand) => l.filesWithdrawUnsupported,
        XControlException(code: 'not_found') => l.filesWithdrawNotFound,
        _ => l.filesNotWithdrawn(describeFileError(l, err)),
      });
}

Future<void> rejectFileFlow(BuildContext context, FileInfo f) async {
  final l = context.l;
  final err = await AppScope.read(context).rejectFile(f.id);
  if (err != null && context.mounted) _snack(context, l.filesNotRejected(describeFileError(l, err)));
}

Future<bool?> _confirmSpecial(BuildContext context, FileInfo f) => showXDialog<bool>(
      context,
      (ctx) => XDialogShell(
        title: ctx.l.filesSpecialTitle,
        icon: Icons.warning_amber_rounded,
        width: 480,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l.commonCancel)),
          FilledButton(
            key: const Key('file-allow-special'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l.filesSpecialAllow),
          ),
        ],
        child: Text(ctx.l.filesSpecialText(f.name), style: XText.body),
      ),
    );

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

/// A file the own-computer rules hold (D-130): Delete and Keep anyway, as a browser's download warning offers. Delete
/// comes first and is the filled one; nothing here takes the focus, so Enter never keeps the file. Keep anyway asks
/// the owner password.
class HeldFileButtons extends StatelessWidget {
  const HeldFileButtons(this.f, {super.key, required this.level});
  final FileInfo f;
  final int level;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      FilledButton(
        key: Key('file-delete-${f.id.substring(0, 8)}'),
        onPressed: () => rejectFileFlow(context, f),
        child: Text(l.filesDelete),
      ),
      OutlinedButton(
        key: Key('file-keep-${f.id.substring(0, 8)}'),
        onPressed: () => acceptFileFlow(context, f, level: level, keep: true),
        child: Text(l.filesKeepAnyway),
      ),
    ]);
  }
}

/// Decision buttons for a checked incoming file.
class FileDecisionButtons extends StatelessWidget {
  const FileDecisionButtons(this.f, {super.key, required this.level, this.showPreview = true});
  final FileInfo f;
  final int level;

  /// Not needed inside the preview window itself.
  final bool showPreview;

  @override
  Widget build(BuildContext context) {
    // A file the own-computer rules hold: Delete and Keep anyway, here and in the preview window alike.
    if (f.held?.holdsByRule ?? false) return HeldFileButtons(f, level: level);
    final l = context.l;
    final dest = fileDestForLevel(level);
    final acceptLabel = f.needsForce
        ? (f.verdict == 'threat' ? l.filesAcceptDespiteThreat : l.filesAcceptDespiteUnchecked)
        : switch (dest) {
            null => l.filesAccept,
            'project' => l.filesAcceptIntoProject,
            final d => l.filesAcceptInto(d),
          };
    final accept = f.needsForce
        ? OutlinedButton(
            key: Key('file-accept-${f.id.substring(0, 8)}'),
            style: XButtons.destructiveFilled(),
            onPressed: () => acceptFileFlow(context, f, level: level),
            child: Text(acceptLabel),
          )
        : FilledButton(
            key: Key('file-accept-${f.id.substring(0, 8)}'),
            onPressed: () => acceptFileFlow(context, f, level: level),
            child: Text(acceptLabel),
          );
    final reject = f.needsForce
        ? FilledButton(
            key: Key('file-reject-${f.id.substring(0, 8)}'),
            onPressed: () => rejectFileFlow(context, f),
            child: Text(l.filesReject),
          )
        : TextButton(
            key: Key('file-reject-${f.id.substring(0, 8)}'),
            onPressed: () => rejectFileFlow(context, f),
            child: Text(l.filesReject),
          );
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      reject,
      if (showPreview)
        OutlinedButton.icon(
        key: Key('file-preview-${f.id.substring(0, 8)}'),
        onPressed: () => showFilePreview(context, f, level: level),
        icon: const Icon(Icons.visibility_outlined, size: 16),
        label: Text(l.filesSafePreview),
      ),
      accept,
    ]);
  }
}
