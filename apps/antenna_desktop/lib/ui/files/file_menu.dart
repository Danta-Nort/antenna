// SPDX-License-Identifier: AGPL-3.0-only
// What the owner can do with a file wherever it shows (D-UI-46): Open it with its app, Show in Finder, Save as…, Copy
// the picture, Copy path, the safe preview, Cancel sending. The same list in the right-click menu and behind the ⋯
// button of a row, a picture and a viewer, and each one works whether or not a picture of the file could be shown.
//
// Open, Show in Finder and Copy path need the file on this computer: a received one the daemon saved, or a sent one
// where the person's own file still is. Save as… copies that file, or, for a picture with no file here, saves the
// picture the window shows (the daemon's rebuilt preview, or the window's preview copy of what it sent). Copy puts that
// picture on the clipboard. Nothing here ever reads a received file the daemon has not saved.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../host/image_actions.dart';
import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../app_scope.dart';
import 'file_actions.dart';
import 'image_thumbnail.dart';
import 'preview_dialog.dart';

/// One action on a file.
enum FileAction { open, reveal, saveAs, copyImage, copyPath, preview, withdraw }

/// What [f] offers here, in menu order.
List<FileAction> fileActionsOf(AppModel m, FileInfo f) {
  final local = m.localFileOf(f) != null;
  final picture = showsThumbnail(m, f) && imagePreviewReady(f);
  return [
    if (local) FileAction.open,
    if (local) FileAction.reveal,
    if (local || picture) FileAction.saveAs,
    if (picture) FileAction.copyImage,
    if (local) FileAction.copyPath,
    // The daemon's safe preview of a received file that is not a picture (text, a PDF's pages, a document's text).
    if (f.incoming && !isImageFile(f) && (f.state == 'checked' || f.state == 'accepted')) FileAction.preview,
    if (!f.incoming && f.state == 'sent' && m.fileWithdrawSupported) FileAction.withdraw,
  ];
}

String fileActionLabel(AppLocalizations l, FileAction a) => switch (a) {
      FileAction.open => l.filesOpenFile,
      FileAction.reveal => Platform.isMacOS ? l.filesShowInFinder : l.filesShowInFolder,
      FileAction.saveAs => l.filesSaveAs,
      FileAction.copyImage => l.filesCopyImage,
      FileAction.copyPath => l.filesCopyPath,
      FileAction.preview => l.filesSafePreview,
      FileAction.withdraw => l.filesWithdraw,
    };

IconData fileActionIcon(FileAction a) => switch (a) {
      FileAction.open => Icons.open_in_new_rounded,
      FileAction.reveal => Icons.folder_open_outlined,
      FileAction.saveAs => Icons.save_alt_rounded,
      FileAction.copyImage => Icons.content_copy_rounded,
      FileAction.copyPath => Icons.link_rounded,
      FileAction.preview => Icons.visibility_outlined,
      FileAction.withdraw => Icons.undo_rounded,
    };

void _say(ScaffoldMessengerState? messenger, String text) =>
    messenger?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));

/// Run [a] on [f]; the outcome is said in a snackbar when it is not visible by itself.
Future<void> runFileAction(BuildContext context, FileInfo f, FileAction a) async {
  final m = AppScope.read(context);
  final l = context.l;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final path = m.localFileOf(f);
  switch (a) {
    case FileAction.open:
      if (path == null || !await m.openLocalFile(path)) _say(messenger, l.filesOpenFailed);
    case FileAction.reveal:
      if (path == null || !await m.revealLocalFile(path)) _say(messenger, l.filesOpenFailed);
    case FileAction.copyPath:
      if (path == null) return;
      await Clipboard.setData(ClipboardData(text: path));
      _say(messenger, l.filesPathCopied);
    case FileAction.copyImage:
      final bytes = await loadImageBytes(context, f);
      final ok = bytes != null && await ImageActions.instance.copyPng(bytes);
      _say(messenger, ok ? l.filesImageCopied : l.filesCopyFailed);
    case FileAction.saveAs:
      if (!context.mounted) return;
      await saveFileAs(context, f);
    case FileAction.preview:
      await showFilePreview(context, f, level: m.contactById(f.linkId)?.trust ?? 0);
    case FileAction.withdraw:
      await withdrawFileFlow(context, f);
  }
}

/// The name a picture with no file here is saved under: its own stem with `.png` (the bytes are a PNG).
String pictureSaveName(String name) {
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name}.png';
}

/// Save as…: the file itself when it is on this computer, else the picture shown for it. `true` when saved.
Future<bool> saveFileAs(BuildContext context, FileInfo f) async {
  final m = AppScope.read(context);
  final l = context.l;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final path = m.localFileOf(f);
  final bytes = path == null ? await loadImageBytes(context, f) : null;
  if (path == null && bytes == null) {
    _say(messenger, l.filesSaveFailed);
    return false;
  }
  final name = path == null ? pictureSaveName(f.name) : (f.savedAs ?? f.name);
  final to = await ImageActions.instance.saveLocation(name);
  if (to == null) return false;
  try {
    if (path != null) {
      await File(path).copy(to);
    } else {
      await File(to).writeAsBytes(bytes!, flush: true);
    }
  } on FileSystemException {
    _say(messenger, l.filesSaveFailed);
    return false;
  }
  _say(messenger, l.filesSavedAs(to));
  return true;
}

/// The menu at [position] (global): the right-click menu of a row or a picture.
Future<void> showFileMenu(BuildContext context, FileInfo f, Offset position) async {
  final m = AppScope.read(context);
  final l = context.l;
  final actions = fileActionsOf(m, f);
  if (actions.isEmpty) return;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final chosen = await showMenu<FileAction>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    items: [
      for (final a in actions)
        PopupMenuItem(
          key: Key('file-menu-${a.name}'),
          value: a,
          height: 36,
          child: Row(children: [
            Icon(fileActionIcon(a), size: 16),
            const SizedBox(width: 12),
            Text(fileActionLabel(l, a)),
          ]),
        ),
    ],
  );
  if (chosen != null && context.mounted) await runFileAction(context, f, chosen);
}

/// The ⋯ button: the same menu, for a mouse without a right button and for keyboard users.
class FileMenuButton extends StatelessWidget {
  const FileMenuButton(this.f, {super.key, this.color, this.size = 18});
  final FileInfo f;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    if (fileActionsOf(m, f).isEmpty) return const SizedBox.shrink();
    return Builder(
      builder: (context) => IconButton(
        key: Key('file-more-${f.id.substring(0, 8)}'),
        tooltip: context.l.filesMore,
        visualDensity: VisualDensity.compact,
        iconSize: size,
        color: color,
        onPressed: () {
          final box = context.findRenderObject()! as RenderBox;
          showFileMenu(context, f, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
        },
        icon: const Icon(Icons.more_horiz_rounded),
      ),
    );
  }
}

/// Right-click (or a two-finger click) on [child] opens [f]'s menu where the pointer is.
class FileContextMenu extends StatelessWidget {
  const FileContextMenu(this.f, {super.key, required this.child});
  final FileInfo f;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onSecondaryTapUp: (d) => showFileMenu(context, f, d.globalPosition),
        child: child,
      );
}
