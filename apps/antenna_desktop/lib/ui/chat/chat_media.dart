// SPDX-License-Identifier: AGPL-3.0-only
// Files in the conversation as a messenger shows them (D-UI-46). A picture is the picture: it fills its bubble at its
// own aspect ratio with rounded corners, bounded in size; its name and size show on hover and in the viewer; the
// check's state is a small badge in its corner. Pictures sent one after another form an album grid. Any other file is
// a compact row: its type icon, name, size and state in one line, a one-line snippet for text, "Saved to …" with Show
// in Finder once it is on this computer. A click opens a picture in the viewer and a file with its app; the right
// click and the ⋯ button have the rest (Open, Show in Finder, Save as…, Copy, Copy path). Only a file that still needs
// the owner's decision with something to read first (a held program, a threat, a name the daemon could not use) keeps
// its full card.
//
// What is shown of a received file is only ever the daemon's safe preview, never the original (`loadImageBytes`).

import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/media.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../files/file_actions.dart';
import '../files/file_card.dart';
import '../files/file_menu.dart';
import '../files/image_thumbnail.dart';

/// How the conversation shows a file.
enum FileLook {
  /// The picture itself (alone, or in an album).
  picture,

  /// A compact row.
  row,

  /// The full card: a decision with something to read first.
  card,
}

/// How [f] shows in the conversation.
FileLook fileLookOf(AppModel m, FileInfo f) {
  if (f.incoming && f.awaitingDecision && (f.held != null || f.needsForce)) return FileLook.card;
  if (isReleaseManifest(f)) return FileLook.card;
  if (f.incoming && (f.state == 'refused' || f.state == 'rejected' || f.withdrawn)) return FileLook.row;
  if (showsThumbnail(m, f) && mediaKindOf(f) == MediaKind.image) return FileLook.picture;
  if (f.incoming && f.awaitingDecision) return FileLook.card;
  return FileLook.row;
}

/// [f] can sit in an album: a picture that waits for nobody.
bool albumable(AppModel m, FileInfo f) => fileLookOf(m, f) == FileLook.picture && !f.awaitingDecision;

/// The pictures of the conversation in [files] (oldest first), for the viewer's Previous and Next.
List<FileInfo> pictureGallery(AppModel m, Iterable<FileInfo> files) =>
    [for (final f in files) if (fileLookOf(m, f) == FileLook.picture) f]
      ..sort((a, b) => a.createdMs.compareTo(b.createdMs));

/// The short state of [f] for its row and its badge: words, color, icon; `null` when there is nothing to say (a
/// received file saved, a sent picture still being offered shows no badge).
(String, Color, IconData)? fileStateLook(AppLocalizations l, AppModel m, FileInfo f) {
  final contact = m.contactById(f.linkId)?.label ?? f.contact;
  if (!f.incoming) {
    return switch (f.state) {
      'accepted' => (l.filesRowDelivered(contact), XColors.ok, Icons.done_all_rounded),
      'held' => (l.filesRowOutHeld(contact), XColors.warn, Icons.hourglass_top_rounded),
      'blocked' => (l.filesRowOutBlocked(contact), XColors.warn, Icons.gpp_maybe_outlined),
      'rejected' => (l.filesRowDeclined, XColors.textMute, Icons.do_not_disturb_on_outlined),
      'withdrawn' => (l.filesRowWithdrawn, XColors.textMute, Icons.undo_rounded),
      _ => (l.filesRowSent, XColors.textMute, Icons.schedule_rounded),
    };
  }
  return switch (f.state) {
    'offered' => (l.filesRowDownloading, XColors.textMute, Icons.downloading_rounded),
    'downloaded' => (l.filesRowChecking, XColors.textMute, Icons.hourglass_top_rounded),
    'checked' when f.held?.holdsByRule ?? false => (l.filesRowHeld, XColors.warn, Icons.warning_amber_rounded),
    'checked' => (l.filesRowWaiting, XColors.accent, Icons.pending_outlined),
    'accepted' => (l.filesRowSaved, XColors.ok, Icons.check_circle_outline),
    'rejected' => (l.filesRowRejected, XColors.textMute, Icons.do_not_disturb_on_outlined),
    'refused' => (refusedLabel(l, f.reason), XColors.danger, Icons.block),
    'withdrawn' => (l.filesRowWithdrawn, XColors.textMute, Icons.undo_rounded),
    _ => null,
  };
}

/// The words of [f]'s check that its picture's badge says: labels and a not-clean verdict (a clean file says nothing).
String? _checkNote(AppLocalizations l, FileInfo f) {
  if (!f.incoming) return null;
  final parts = <String>[
    if (f.verdict != null && f.verdict != 'clean') verdictLook(l, f.verdict).$1,
    ...f.labels,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The picture of a file in a box of [width] × [height]: the bytes once loaded (cover), a quiet placeholder before.
/// [onNone] is what shows when there is no picture after all (the caller's fallback: a row, an icon tile).
class _Picture extends StatefulWidget {
  const _Picture(this.f, {required this.width, required this.height, required this.onNone});
  final FileInfo f;
  final double width;
  final double height;
  final WidgetBuilder onNone;

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = loadImageBytes(context, widget.f);
  }

  @override
  void didUpdateWidget(covariant _Picture old) {
    super.didUpdateWidget(old);
    if (old.f.id != widget.f.id || old.f.state != widget.f.state) _future = loadImageBytes(context, widget.f);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _future,
        builder: (context, s) {
          final bytes = s.data;
          if (s.connectionState == ConnectionState.done && bytes == null && imagePreviewReady(widget.f)) {
            return widget.onNone(context);
          }
          final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
          final size = bytes == null ? null : imageSizeOf(bytes);
          // Decode at the size it is drawn (the longer of the two sides the cover crop needs), not at the preview's.
          final wide = size != null && size.$1 / size.$2 > widget.width / widget.height;
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: bytes == null
                ? ColoredBox(
                    color: XColors.bg2,
                    child: Center(
                      child: imagePreviewReady(widget.f)
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.image_outlined, size: 24, color: XColors.textMute),
                    ),
                  )
                : Image.memory(
                    bytes,
                    key: Key('chat-picture-img-${widget.f.id.substring(0, 8)}'),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                    cacheWidth: wide ? null : (widget.width * dpr).round(),
                    cacheHeight: wide ? (widget.height * dpr).round() : null,
                    errorBuilder: (_, e, _) {
                      debugPrint('files: ${widget.f.id.substring(0, 8)}: the picture did not decode: $e');
                      return ColoredBox(
                          color: XColors.bg2,
                          child: Center(child: Icon(Icons.broken_image_outlined, color: XColors.textMute)));
                    },
                  ),
          );
        },
      );
}

/// The small round badge in a picture's corner: the check's state or the sent file's fate, said in its tooltip.
class _Badge extends StatelessWidget {
  const _Badge(this.f);
  final FileInfo f;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final state = fileStateLook(l, m, f);
    final note = _checkNote(l, f);
    // A saved received picture with nothing to note, and a sent one still offered, need no badge.
    final quiet = (f.incoming && f.state == 'accepted' && note == null) || (!f.incoming && f.state == 'sent');
    if (state == null || quiet) return const SizedBox.shrink();
    final (text, color, icon) = state;
    return Tooltip(
      message: [text, ?note].join(' · '),
      child: Container(
        key: Key('chat-picture-badge-${f.id.substring(0, 8)}'),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: XColors.bg1.withValues(alpha: 0.92),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: XColors.shadow, blurRadius: 4)],
        ),
        child: Icon(note != null && f.state == 'accepted' ? Icons.info_outline_rounded : icon, size: 14, color: color),
      ),
    );
  }
}

/// What a tap on a picture does: the viewer over the conversation's pictures.
void _openViewer(BuildContext context, FileInfo f, List<FileInfo> gallery) {
  final list = gallery.any((x) => x.id == f.id) ? gallery : [f];
  final index = list.indexWhere((x) => x.id == f.id);
  showImageViewer(context, [for (final x in list) viewerImageOf(x)], initialIndex: index < 0 ? 0 : index);
}

/// One tile of a picture: the picture, its badge, its name and size on hover, the viewer on a click, the menu on a
/// right click.
class _PictureTile extends StatefulWidget {
  const _PictureTile(this.f, {required this.width, required this.height, required this.gallery, required this.onNone});
  final FileInfo f;
  final double width;
  final double height;
  final List<FileInfo> gallery;
  final WidgetBuilder onNone;

  @override
  State<_PictureTile> createState() => _PictureTileState();
}

class _PictureTileState extends State<_PictureTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.f;
    final id = f.id.substring(0, 8);
    final l = context.l;
    return FileContextMenu(
      f,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Semantics(
          button: true,
          image: true,
          label: '${l.filesImageOpen}: ${f.name}',
          child: InkWell(
            key: Key('chat-picture-$id'),
            onTap: imagePreviewReady(f) ? () => _openViewer(context, f, widget.gallery) : null,
            child: Stack(children: [
              _Picture(f, width: widget.width, height: widget.height, onNone: widget.onNone),
              Positioned(top: 6, right: 6, child: _Badge(f)),
              if (_hover)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    key: Key('chat-picture-caption-$id'),
                    padding: const EdgeInsets.fromLTRB(8, 16, 4, 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0xA6000000)],
                      ),
                    ),
                    child: Row(children: [
                      Expanded(
                        // The name is contact data: plain text.
                        child: Text('${f.name} · ${fileSizeLabel(f.size)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: XText.meta.copyWith(color: Colors.white)),
                      ),
                      FileMenuButton(f, color: Colors.white, size: 16),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A single picture in the conversation, at its own aspect ratio within the bubble's bounds; the decision buttons
/// under it while the owner (or the contact's level) still has to accept it. No picture after all (a file accepted
/// by an older version has none): the compact row instead.
class ChatPicture extends StatefulWidget {
  const ChatPicture(this.f, {super.key, required this.gallery, this.maxWidth = 320});
  final FileInfo f;
  final List<FileInfo> gallery;
  final double maxWidth;

  @override
  State<ChatPicture> createState() => _ChatPictureState();
}

/// Picture sizes already seen (file ID → pixels), so a rebuilt row keeps its size instead of jumping.
final _sizes = <String, (int, int)>{};

class _ChatPictureState extends State<ChatPicture> {
  (int, int)? _size;
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _size = _sizes[widget.f.id];
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant ChatPicture old) {
    super.didUpdateWidget(old);
    if (old.f.id != widget.f.id || old.f.state != widget.f.state) _future = _load();
  }

  Future<Uint8List?> _load() async {
    final b = await loadImageBytes(context, widget.f);
    final s = b == null ? null : imageSizeOf(b);
    if (s != null && s != _size) {
      _sizes[widget.f.id] = s;
      if (mounted) setState(() => _size = s);
    }
    return b;
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.f;
    final m = AppScope.of(context);
    final level = m.contactById(f.linkId)?.trust ?? 0;
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, s) {
        // No picture after all (a file accepted by an older version kept none): the file as a row, with its actions.
        if (s.connectionState == ConnectionState.done && s.data == null && imagePreviewReady(f)) {
          return FileRowCompact(f, key: Key('chat-picture-none-${f.id.substring(0, 8)}'));
        }
        final (w, h) = inlineSize(_size, maxW: widget.maxWidth, maxH: widget.maxWidth);
        return Column(
          key: Key('chat-picture-box-${f.id.substring(0, 8)}'),
          crossAxisAlignment: f.incoming ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Framed(
              child: _PictureTile(f,
                  width: w, height: h, gallery: widget.gallery, onNone: (_) => SizedBox(width: w, height: h)),
            ),
            if (f.awaitingDecision) ...[
              const SizedBox(height: 8),
              Text(levelRuleLabel(context.l, level), style: XText.meta),
              const SizedBox(height: 8),
              FileDecisionButtons(f, level: level),
            ],
          ],
        );
      },
    );
  }
}

/// Pictures sent one after another, as one grid: the first row wider when the count does not divide (see
/// [albumRows]); each tile opens the viewer over the whole conversation.
class ChatAlbum extends StatelessWidget {
  const ChatAlbum(this.files, {super.key, required this.gallery, this.width = 320, this.gap = 2});
  final List<FileInfo> files;
  final List<FileInfo> gallery;
  final double width;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final rows = albumRows(files.length);
    var i = 0;
    return _Framed(
      key: Key('chat-album-${files.first.id.substring(0, 8)}'),
      child: SizedBox(
        width: width,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var r = 0; r < rows.length; r++) ...[
            if (r > 0) SizedBox(height: gap),
            Builder(builder: (context) {
              final n = rows[r];
              final tileW = (width - gap * (n - 1)) / n;
              final tileH = n == 1 ? width * 0.62 : tileW;
              final row = files.sublist(i, i + n);
              i += n;
              return Row(children: [
                for (var k = 0; k < row.length; k++) ...[
                  if (k > 0) SizedBox(width: gap),
                  _PictureTile(row[k],
                      width: tileW,
                      height: tileH,
                      gallery: gallery,
                      onNone: (_) => _IconTile(row[k], width: tileW, height: tileH)),
                ],
              ]);
            }),
          ],
        ]),
      ),
    );
  }
}

/// A picture as a square [side] wide (cover), with the same hover caption, badge, viewer and menu as in the
/// conversation: the grids of Media and files and of the Files screen. No picture to show: its type icon and name.
class PictureSquare extends StatelessWidget {
  const PictureSquare(this.f, {super.key, required this.side, required this.gallery});
  final FileInfo f;
  final double side;
  final List<FileInfo> gallery;

  @override
  Widget build(BuildContext context) => ClipRRect(
        key: Key('picture-square-${f.id.substring(0, 8)}'),
        borderRadius: BorderRadius.circular(XRadius.m),
        child: _PictureTile(f,
            width: side,
            height: side,
            gallery: gallery,
            onNone: (_) => _IconTile(f, width: side, height: side)),
      );
}

/// Rounded corners and a hairline edge, so that a white picture on the light theme still reads as a picture.
class _Framed extends StatelessWidget {
  const _Framed({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(XRadius.bubble),
          border: Border.all(color: XColors.line),
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(XRadius.bubble), child: child),
      );
}

/// A tile with the file's type icon and name, where an album's picture cannot be shown.
class _IconTile extends StatelessWidget {
  const _IconTile(this.f, {required this.width, required this.height});
  final FileInfo f;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        color: XColors.bg2,
        padding: const EdgeInsets.all(8),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(fileIcon(f), color: XColors.textMute),
          const SizedBox(height: 4),
          Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: XText.meta),
        ]),
      );
}

/// One-line snippets of received text files (file ID → the first line of the safe preview), fetched once each.
final _snippets = <String, String?>{};
final _snippetJobs = <String, Future<String?>>{};

Future<String?> _snippetOf(BuildContext context, FileInfo f) {
  if (_snippets.containsKey(f.id)) return Future.value(_snippets[f.id]);
  final m = AppScope.read(context);
  return _snippetJobs[f.id] ??= () async {
    String? s;
    try {
      s = snippetOf((await m.previewFile(f.id)).preview?.text);
    } on Object {
      s = null;
    }
    _snippets[f.id] = s;
    return s;
  }();
}

/// A file as a compact row: type icon, name, size and state in one line; under it a text file's first line, "Saved to
/// …" with Show in Finder, or why a sent file waits. A click opens the file with its app when it is on this computer,
/// else its safe preview.
class FileRowCompact extends StatefulWidget {
  const FileRowCompact(this.f, {super.key, this.showContact = false, this.maxWidth = 440});
  final FileInfo f;
  final bool showContact;
  final double maxWidth;

  @override
  State<FileRowCompact> createState() => _FileRowCompactState();
}

class _FileRowCompactState extends State<FileRowCompact> {
  Future<String?>? _snippet;

  @override
  void initState() {
    super.initState();
    _askSnippet();
  }

  @override
  void didUpdateWidget(covariant FileRowCompact old) {
    super.didUpdateWidget(old);
    if (old.f.state != widget.f.state) _askSnippet();
  }

  void _askSnippet() {
    final f = widget.f;
    final readable = f.incoming && (f.state == 'checked' || f.state == 'accepted') && f.verdict != 'threat';
    if (readable && mediaKindOf(f) == MediaKind.text) _snippet = _snippetOf(context, f);
  }

  Future<void> _tap(BuildContext context) async {
    final m = AppScope.read(context);
    final actions = fileActionsOf(m, widget.f);
    for (final a in [FileAction.open, FileAction.preview]) {
      if (actions.contains(a)) return runFileAction(context, widget.f, a);
    }
    if (showsThumbnail(m, widget.f) && imagePreviewReady(widget.f)) {
      _openViewer(context, widget.f, [widget.f]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.f;
    final l = context.l;
    final m = AppScope.of(context);
    final id = f.id.substring(0, 8);
    final state = fileStateLook(l, m, f);
    final saved = m.localFileOf(f);
    // The second line: what the card would say about the state (the same words and keys), "Saved to …" with Show in
    // Finder, Cancel sending, or a text file's first line.
    final plainSaved = f.incoming && f.state == 'accepted' && !f.renamed && !f.duplicate;
    final quiet =
        (!f.incoming && f.state == 'sent') || (f.incoming && f.state == 'refused') || (plainSaved && saved != null);
    final note = quiet ? null : FileStatusNote.of(context, f);
    final second = <Widget>[
      ?note,
      if (f.incoming && f.state == 'accepted' && saved != null) _SavedTo(f, saved),
      if (!f.incoming && f.state == 'sent' && m.fileWithdrawSupported) _CancelSending(f),
      if (note == null && _snippet != null)
        FutureBuilder<String?>(
          future: _snippet,
          builder: (context, s) => s.data == null
              ? const SizedBox.shrink()
              : Text(s.data!,
                  key: Key('file-row-snippet-$id'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: XText.monoSmall.copyWith(color: XColors.textDim)),
        ),
    ];
    // The note already says the fate of a sent file, and a received file's decision: no short state beside the name.
    final shownState = note != null && !(f.incoming && f.state == 'accepted') ? null : state;
    return FileContextMenu(
      f,
      child: Container(
        key: Key('file-row-$id'),
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, border: XColors.line),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(XRadius.l),
            onTap: () => _tap(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
              child: Row(children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: XColors.accentSoft, borderRadius: BorderRadius.circular(XRadius.m)),
                  child: Icon(fileIcon(f), color: XColors.accent, size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      // The name is contact data: one line, no markup.
                      Flexible(
                        child: Text(f.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: XText.body.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        [
                          fileSizeLabel(f.size),
                          if (widget.showContact) f.incoming ? l.filesFrom(f.contact) : l.filesTo(f.contact),
                        ].join(' · '),
                        style: XText.meta,
                      ),
                      if (shownState != null) ...[
                        const SizedBox(width: 8),
                        Icon(shownState.$3, size: 13, color: shownState.$2),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(shownState.$1,
                              key: Key('file-row-state-$id'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: XText.meta.copyWith(color: shownState.$2)),
                        ),
                      ],
                    ]),
                    for (final w in second) Padding(padding: const EdgeInsets.only(top: 2), child: w),
                  ]),
                ),
                FileMenuButton(f),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Cancel sending" under a sent file the contact has not answered (preview.5), and for a contact whose node cannot
/// delete its copy, what that means.
class _CancelSending extends StatelessWidget {
  const _CancelSending(this.f);
  final FileInfo f;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = AppScope.of(context).contactById(f.linkId);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
      TextButton(
        key: Key('file-withdraw-${f.id.substring(0, 8)}'),
        style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 22),
            visualDensity: VisualDensity.compact, textStyle: XText.meta),
        onPressed: () => withdrawFileFlow(context, f),
        child: Text(l.filesWithdraw),
      ),
      if (c != null && !c.peerFileWithdraw) Text(l.filesWithdrawOldContact, style: XText.meta),
    ]);
  }
}

/// "Saved to ~/Desktop/report.pdf" and Show in Finder, for a received file on this computer.
class _SavedTo extends StatelessWidget {
  const _SavedTo(this.f, this.path);
  final FileInfo f;
  final String path;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final id = f.id.substring(0, 8);
    return Row(children: [
      Flexible(
        child: Text(l.filesSavedTo(shortPath(path, home: Platform.environment['HOME'])),
            key: Key('file-saved-to-$id'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: XText.meta.copyWith(color: XColors.textDim)),
      ),
      TextButton(
        key: Key('file-saved-reveal-$id'),
        style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 22),
            visualDensity: VisualDensity.compact, textStyle: XText.meta),
        onPressed: () => runFileAction(context, f, FileAction.reveal),
        child: Text(Platform.isMacOS ? l.filesShowInFinder : l.filesShowInFolder),
      ),
    ]);
  }
}
