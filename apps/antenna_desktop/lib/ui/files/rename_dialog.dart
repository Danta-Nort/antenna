// SPDX-License-Identifier: AGPL-3.0-only
// "Another name" for a received file whose name is taken in the link folder (CONTROL §14, "A name that is taken").
// The field starts with the daemon's own free suggestion (`report (2).pdf`); every edit is checked with
// `file_name_check` after a short pause, and Accept stays disabled, with the reason shown, while the name is taken or
// breaks the naming rules. The dialog accepts the file itself, so every refusal of `file_accept` is shown here and
// the dialog stays open: a name taken in between by another process, a quota, the connection.
//
// A daemon older than preview.8 cannot check names: the dialog then starts with the contact's name, refuses to send
// again a name the daemon has already refused (it would only refuse it again, which is how a preview.5 window looked
// as if Accept did nothing), and shows whatever the accept answers.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/dialog_shell.dart';
import 'file_actions.dart' show describeFileError;

/// What the dialog's accept returns when the owner declined a follow-up question (a special name): nothing to show.
final class AcceptDeclined {
  const AcceptDeclined();
}

/// Open "Another name" for [f] after the daemon refused its name with [refused]. [accept] accepts the file under a
/// name and returns the daemon's error, `null`, or [AcceptDeclined]. `true` when the file was accepted.
Future<bool?> showFileRenameDialog(BuildContext context, FileInfo f,
        {required XControlException refused, required Future<Object?> Function(String name) accept}) =>
    showXDialog<bool>(context, (_) => FileRenameDialog(file: f, refused: refused, accept: accept));

class FileRenameDialog extends StatefulWidget {
  const FileRenameDialog({super.key, required this.file, required this.refused, required this.accept});
  final FileInfo file;
  final XControlException refused;
  final Future<Object?> Function(String name) accept;

  /// The pause after the last keystroke before the name is checked.
  static const debounce = Duration(milliseconds: 300);

  @override
  State<FileRenameDialog> createState() => _FileRenameDialogState();
}

class _FileRenameDialogState extends State<FileRenameDialog> {
  final _c = TextEditingController();
  Timer? _debounce;

  /// The daemon's answer for [_checkedName] (`null`: none yet, or the daemon cannot check).
  FileNameCheck? _check;
  String? _checkedName;
  bool _checking = true;

  /// Names the daemon refused at the accept (lower-cased, as it compares them): never sent again as they are.
  final Set<String> _refusedNames = {};
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _refusedNames.add(widget.file.name.toLowerCase());
    _c.text = widget.file.name;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  /// The contact's name first: the daemon answers with a free name to start from.
  Future<void> _start() async {
    final m = AppScope.read(context);
    final r = await m.checkFileName(widget.file.id);
    if (!mounted) return;
    final suggestion = r?.suggestion;
    if (r != null && r.taken && suggestion != null && suggestion.isNotEmpty) {
      _c.text = suggestion;
      _c.selection = TextSelection(baseOffset: 0, extentOffset: _stemLength(suggestion));
      await _runCheck(suggestion);
      return;
    }
    setState(() {
      _checking = false;
      _check = r;
      _checkedName = r == null ? null : widget.file.name;
    });
  }

  /// The name before its extension: what the owner most likely edits.
  static int _stemLength(String n) {
    final dot = n.lastIndexOf('.');
    return dot > 0 ? dot : n.length;
  }

  void _changed(String _) {
    _debounce?.cancel();
    setState(() {
      _checking = AppScope.read(context).fileNameCheckSupported;
      _error = null;
    });
    _debounce = Timer(FileRenameDialog.debounce, () => _runCheck(_c.text.trim()));
  }

  Future<void> _runCheck(String name) async {
    final m = AppScope.read(context);
    if (name.isEmpty || !m.fileNameCheckSupported) {
      setState(() => _checking = false);
      return;
    }
    setState(() => _checking = true);
    final r = await m.checkFileName(widget.file.id, name: name);
    // Only the answer for what the field still says counts.
    if (!mounted || _c.text.trim() != name) return;
    setState(() {
      _check = r;
      _checkedName = name;
      _checking = false;
    });
  }

  String get _name => _c.text.trim();

  /// Accept is enabled only for a name the daemon said is free (or holds the same file), or, when it cannot check,
  /// for a name it has not refused already.
  bool get _canAccept {
    final n = _name;
    if (_busy || n.isEmpty || _checking) return false;
    // A name the accept itself refused stays refused here, whatever a check said since: no loop of the same refusal.
    if (_refusedNames.contains(n.toLowerCase())) return false;
    final c = _check;
    if (c == null || _checkedName != n) return !AppScope.read(context).fileNameCheckSupported;
    return c.free || c.sameFile;
  }

  Future<void> _accept() async {
    if (!_canAccept) return;
    final name = _name;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.accept(name);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      if (err is! AcceptDeclined) _error = err;
      if (err is XControlException && (err.code == XErrorCode.fileNameTaken || err.code == XErrorCode.badFileName)) {
        _refusedNames.add(name.toLowerCase());
      }
    });
    // Taken in between: the daemon's view of the folder changed, ask again (with a new suggestion).
    if (err is XControlException && err.code == XErrorCode.fileNameTaken) await _runCheck(name);
  }

  /// Why Accept is disabled, or what the check found.
  (String, Color)? _status(AppLocalizations l) {
    final n = _name;
    if (n.isEmpty) return (l.filesRenameEmpty, XColors.warn);
    if (_checking) return (l.filesRenameChecking, XColors.textMute);
    final c = _check != null && _checkedName == n ? _check : null;
    if (c != null && c.invalid) return (l.filesRenameInvalid(c.message ?? ''), XColors.warn);
    if (c != null && !c.free && !c.sameFile) return (l.filesRenameTaken, XColors.warn);
    if (_refusedNames.contains(n.toLowerCase())) return (l.filesRenameRefused, XColors.warn);
    if (c == null) return AppScope.read(context).fileNameCheckSupported ? null : (l.filesRenameNoCheck, XColors.textMute);
    return c.free ? (l.filesRenameFree, XColors.ok) : (l.filesRenameSame, XColors.ok);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final status = _status(l);
    final suggestion = _check != null && _checkedName == _name && _check!.taken ? _check!.suggestion : null;
    return XDialogShell(
      key: const Key('file-rename-dialog'),
      title: l.filesRenameTitle,
      icon: Icons.drive_file_rename_outline,
      width: 480,
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('file-rename-accept'),
          onPressed: _canAccept ? _accept : null,
          child: Text(l.filesRenameAccept),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Why the dialog is open: the daemon's own answer to the first accept.
        Text(
          widget.refused.code == XErrorCode.badFileName
              ? l.filesRenameWhyInvalid(widget.file.name)
              : l.filesRenameWhyTaken(widget.file.name),
          style: XText.bodyDim,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('file-name'),
          controller: _c,
          autofocus: true,
          enabled: !_busy,
          decoration: InputDecoration(labelText: l.filesRenameLabel),
          onChanged: _changed,
          onSubmitted: (_) => _accept(),
        ),
        if (status case (final text, final color))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Expanded(
                child: Text(text, key: const Key('file-rename-status'), style: XText.meta.copyWith(color: color)),
              ),
              if (suggestion != null && suggestion.isNotEmpty)
                TextButton(
                  key: const Key('file-rename-suggestion'),
                  onPressed: () {
                    _c.text = suggestion;
                    _changed(suggestion);
                  },
                  child: Text(l.filesRenameUse(suggestion)),
                ),
            ]),
          ),
        if (_error case final e?) ErrorLine(l.filesNotAccepted(describeFileError(l, e)), key: const Key('file-rename-error')),
      ]),
    );
  }
}
