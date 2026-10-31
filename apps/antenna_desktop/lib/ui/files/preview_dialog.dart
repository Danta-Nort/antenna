// SPDX-License-Identifier: AGPL-3.0-only
// Safe preview of a quarantined file. It is not the file itself but a copy the daemon rebuilt in an isolated process:
// images and PDF pages are redrawn from pixels by its own PNG encoder, and text is cleaned of invisible characters and
// hidden text. The original stays in quarantine and has not been opened on this computer.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/dialog_shell.dart';
import 'file_actions.dart';
import 'file_card.dart';

Future<void> showFilePreview(BuildContext context, FileInfo f, {required int level}) =>
    showXDialog<void>(context, (_) => FilePreviewDialog(f, level: level));

class FilePreviewDialog extends StatefulWidget {
  const FilePreviewDialog(this.f, {super.key, required this.level, this.initial});
  final FileInfo f;
  final int level;

  /// For tests and goldens: a ready daemon response.
  final FilePreviewReply? initial;

  @override
  State<FilePreviewDialog> createState() => _FilePreviewDialogState();
}

class _FilePreviewDialogState extends State<FilePreviewDialog> {
  late Future<FilePreviewReply> _r = widget.initial != null
      ? Future.value(widget.initial)
      : AppScope.read(context).previewFile(widget.f.id);

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final f = m.files[widget.f.id] ?? widget.f;
    return XDialogShell(
      title: f.name,
      icon: fileIcon(f),
      subtitle: l.filesPreviewSubtitle(fileSizeLabel(f.size), f.mime ?? f.senderMime, f.contact),
      width: 820,
      actions: [
        if (f.awaitingDecision) FileDecisionButtons(f, level: widget.level, showPreview: false),
        if (!f.awaitingDecision) FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.commonClose)),
      ],
      child: FutureBuilder<FilePreviewReply>(
        future: _r,
        builder: (context, s) {
          if (s.hasError) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.filesPreviewFailed(describeFileError(l, s.error)),
                  style: XText.bodyDim.copyWith(color: XColors.danger)),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _r = AppScope.read(context).previewFile(widget.f.id)),
                child: Text(l.filesTryAgain),
              ),
            ]);
          }
          if (!s.hasData) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          return _PreviewBody(s.data!);
        },
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody(this.r);
  final FilePreviewReply r;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final p = r.preview;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        key: const Key('preview-honesty'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: XColors.accentSoft, borderRadius: BorderRadius.circular(XRadius.m)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.shield_outlined, size: 18, color: XColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              p == null
                  ? l.filesPreviewNone
                  : switch (p.kind) {
                      'image' => l.filesPreviewImage,
                      'pdf' || 'document' => l.filesPreviewPages,
                      'text' => l.filesPreviewText,
                      'archive' => l.filesPreviewArchive,
                      _ => l.filesPreviewNoType,
                    },
              style: XText.bodyDim.copyWith(color: XColors.text),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      if (p == null || (p.imagesPng.isEmpty && (p.text ?? '').isEmpty))
        _Empty(r.file)
      else ...[
        for (var i = 0; i < p.imagesPng.length; i++) ...[
          if (p.imagesPng.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                p.truncated ? l.filesPageOfMore(i + 1, p.imagesPng.length) : l.filesPageOf(i + 1, p.imagesPng.length),
                style: XText.meta,
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: XColors.qrPaper,
              borderRadius: BorderRadius.circular(XRadius.s),
              border: Border.all(color: XColors.line),
            ),
            clipBehavior: Clip.antiAlias,
            constraints: const BoxConstraints(maxHeight: 520),
            child: Image.memory(
              p.imagesPng[i],
              key: Key('preview-image-$i'),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l.filesPreviewImageError, style: XText.meta),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if ((p.text ?? '').isNotEmpty)
          Container(
            key: const Key('preview-text'),
            padding: const EdgeInsets.all(16),
            constraints: const BoxConstraints(maxHeight: 420),
            decoration: BoxDecoration(
              color: XColors.bg2,
              borderRadius: BorderRadius.circular(XRadius.m),
              border: Border.all(color: XColors.line),
            ),
            // The contact's text is data only: monospaced, no markup or links.
            child: SingleChildScrollView(
              child: SelectableText(p.text!, style: XText.mono.copyWith(color: XColors.text, height: 1.5)),
            ),
          ),
        if (p.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(l.filesPreviewTruncated, style: XText.meta),
          ),
      ],
    ]);
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.f);
  final FileInfo f;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          switch (f.verdict) {
            'threat' => context.l.filesEmptyThreat,
            'failed' => context.l.filesEmptyFailed,
            _ => context.l.filesEmptyNoType,
          },
          style: XText.bodyDim,
        ),
      );
}
