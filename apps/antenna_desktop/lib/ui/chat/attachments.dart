// SPDX-License-Identifier: AGPL-3.0-only
// Files waiting in the composer for Send (`FilesMixin.staged`), as messengers show them (D-UI-46): a picture is a
// small square of the picture itself, any other file a chip with its type icon, name and size. Every one has an ✕;
// a click (or Space when focused) opens a picture in the viewer and a file with its app; dragging one changes the
// order, which is the order of sending and so of the album the contact sees. A file the daemon refused stays as a chip
// with the reason, or "Approve and send" for a secret. A line under them says who gets them.
//
// The pictures here are the owner's own files (the window's staged copy), decoded by the window as before.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/files.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../files/file_actions.dart';
import '../files/file_card.dart' show fileSizeLabel;
import '../files/image_viewer.dart';

/// Thumbnails are decoded only for images up to this size (the window's own copies; a larger one gets an icon).
const _thumbLimit = 32 << 20;

/// The side of a picture's square in the composer.
const attachmentTileSide = 72.0;

class StagedAttachments extends StatelessWidget {
  const StagedAttachments(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final list = m.stagedOf(c.linkId);
    if (list.isEmpty) return const SizedBox.shrink();
    // The exact recipient of these files: the agent of this chat, everyone there, or the person.
    final addr = m.fileAddressOf(c.linkId);
    final to = switch (addr) {
      (to: 'agent', toAgent: final agent?) => l.chatAgentTitle(c.label, agent),
      (to: 'everyone', toAgent: _) => l.chatAgentTitle(c.label, l.authorToEveryone),
      _ when m.chatsSupported => l.mapPersonOf(c.label),
      _ => c.label,
    };
    final pictures = [for (final a in list) if (_showsPicture(a)) a];
    return Padding(
      key: const Key('staged-attachments'),
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: attachmentTileSide + 4,
          child: ReorderableListView.builder(
            key: const Key('staged-attachments-list'),
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            itemCount: list.length,
            onReorderItem: (from, to) => m.reorderStaged(c.linkId, from, to),
            proxyDecorator: (child, _, _) => Material(type: MaterialType.transparency, child: child),
            itemBuilder: (context, i) {
              final a = list[i];
              return Padding(
                key: ValueKey('attachment-slot-${a.id}'),
                padding: const EdgeInsets.only(right: 8, top: 2, bottom: 2),
                child: ReorderableDragStartListener(
                  index: i,
                  enabled: !a.busy && list.length > 1,
                  child: _showsPicture(a)
                      ? AttachmentTile(c.linkId, a, pictures: pictures)
                      : Center(child: AttachmentChip(c.linkId, a, pictures: pictures)),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          list.length > 1
              ? '${l.composerAttachmentsHint(to)} ${l.composerAttachmentsOrder}'
              : l.composerAttachmentsHint(to),
          key: const Key('staged-attachments-to'),
          style: XText.meta,
        ),
      ]),
    );
  }
}

/// [a] shows as the picture itself: an image the window can decode, with nothing wrong to say.
bool _showsPicture(StagedAttachment a) =>
    a.isImage && (a.size ?? _thumbLimit + 1) <= _thumbLimit && a.error == null && a.approvalId == null;

/// What a click does: a picture in the viewer over the composer's pictures, any other file with its app.
Future<void> _open(BuildContext context, StagedAttachment a, List<StagedAttachment> pictures) async {
  if (_showsPicture(a)) {
    final list = pictures.contains(a) ? pictures : [a];
    await showImageViewer(
      context,
      [
        for (final p in list)
          ViewerImage(
            id: p.id,
            name: p.name,
            size: p.size,
            load: (_) async {
              try {
                return await File(p.file.path).readAsBytes();
              } on FileSystemException {
                return null;
              }
            },
          ),
      ],
      initialIndex: list.indexOf(a),
    );
    return;
  }
  final m = AppScope.read(context);
  final failed = context.l.filesOpenFailed;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final path = a.file.origin != null && File(a.file.origin!).existsSync() ? a.file.origin! : a.file.path;
  if (!await m.openLocalFile(path)) messenger?.showSnackBar(SnackBar(content: Text(failed)));
}

/// A picture waiting for Send: the picture itself in a square, its ✕ in the corner, the name in its tooltip.
class AttachmentTile extends StatelessWidget {
  AttachmentTile(this.linkId, this.a, {required this.pictures}) : super(key: Key('attachment-${a.id}'));
  final String linkId;
  final StagedAttachment a;
  final List<StagedAttachment> pictures;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.read(context);
    return Tooltip(
      message: [a.name, if (a.size != null) fileSizeLabel(a.size!)].join(' · '),
      waitDuration: const Duration(milliseconds: 500),
      child: SizedBox(
        width: attachmentTileSide,
        height: attachmentTileSide,
        child: Stack(children: [
          Positioned.fill(
            child: Material(
              color: XColors.bg2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(XRadius.m),
                side: BorderSide(color: XColors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: Key('attachment-open-${a.id}'),
                onTap: a.busy ? null : () => _open(context, a, pictures),
                child: Image.file(
                  File(a.file.path),
                  key: Key('attachment-thumb-${a.id}'),
                  fit: BoxFit.cover,
                  cacheWidth: (attachmentTileSide * 2).round(),
                  errorBuilder: (_, _, _) => Icon(Icons.image_outlined, color: XColors.accent),
                ),
              ),
            ),
          ),
          if (a.busy)
            Positioned.fill(
              child: ColoredBox(
                color: XColors.bg1.withValues(alpha: 0.6),
                child: const Center(
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
            )
          else
            Positioned(
              top: 2,
              right: 2,
              child: _RemoveButton(
                key: Key('attachment-remove-${a.id}'),
                tooltip: l.composerAttachmentRemove,
                onTap: () => m.unstage(linkId, a),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The ✕ on a picture: small and round, readable over any picture.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({super.key, required this.tooltip, required this.onTap});
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.black.withValues(alpha: 0.55),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close_rounded, size: 14, color: Colors.white),
            ),
          ),
        ),
      );
}

/// Any other file waiting for Send, and a picture the daemon refused: icon (or a small picture), name, size or what
/// went wrong, the ✕.
class AttachmentChip extends StatelessWidget {
  AttachmentChip(this.linkId, this.a, {this.pictures = const []}) : super(key: Key('attachment-${a.id}'));
  final String linkId;
  final StagedAttachment a;
  final List<StagedAttachment> pictures;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.read(context);
    final problem = a.error != null || a.approvalId != null;
    final String status;
    if (a.busy) {
      status = l.composerAttachmentSending;
    } else if (a.approvalId != null) {
      status = l.composerAttachmentSecret;
    } else if (a.error != null) {
      status = describeFileError(l, a.error);
    } else {
      status = a.size == null ? '' : fileSizeLabel(a.size!);
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      decoration: BoxDecoration(
        color: XColors.bg2,
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(color: problem ? XColors.warn : XColors.line),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('attachment-open-${a.id}'),
          borderRadius: BorderRadius.circular(XRadius.m),
          onTap: a.busy ? null : () => _open(context, a, pictures),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 2, 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _Thumb(a),
              const SizedBox(width: 8),
              Flexible(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: XText.body.copyWith(fontSize: 12)),
                  // The state and, for a secret, its button on one line: the chip keeps the height of the list.
                  if (status.isNotEmpty)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(
                        child: Tooltip(
                          message: status,
                          child: Text(status,
                              maxLines: a.approvalId != null && !a.busy ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: XText.meta.copyWith(color: problem ? XColors.warn : null)),
                        ),
                      ),
                      if (a.approvalId != null && !a.busy)
                        TextButton(
                          key: Key('attachment-approve-${a.id}'),
                          style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              minimumSize: const Size(0, 22),
                              visualDensity: VisualDensity.compact),
                          onPressed: () => approveStaged(context, linkId, a),
                          child: Text(l.filesApproveAndSend),
                        ),
                    ]),
                ]),
              ),
              if (a.busy)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                IconButton(
                  key: Key('attachment-remove-${a.id}'),
                  tooltip: l.composerAttachmentRemove,
                  onPressed: () => m.unstage(linkId, a),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded, size: 16, color: XColors.textDim),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb(this.a);
  final StagedAttachment a;

  @override
  Widget build(BuildContext context) {
    final icon = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: XColors.accentSoft, borderRadius: BorderRadius.circular(XRadius.s)),
      child: Icon(_iconFor(a), size: 20, color: XColors.accent),
    );
    if (!a.isImage || (a.size ?? _thumbLimit + 1) > _thumbLimit) return icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(XRadius.s),
      child: Image.file(
        File(a.file.path),
        key: Key('attachment-thumb-${a.id}'),
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        cacheWidth: 80,
        errorBuilder: (_, _, _) => icon,
      ),
    );
  }

  static IconData _iconFor(StagedAttachment a) {
    final ext = a.name.contains('.') ? a.name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'heic' => Icons.image_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'txt' || 'md' || 'csv' || 'json' || 'log' => Icons.description_outlined,
      'zip' || 'gz' || 'tgz' || 'tar' || '7z' => Icons.folder_zip_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}
