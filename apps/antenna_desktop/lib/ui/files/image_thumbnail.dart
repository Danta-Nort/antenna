// SPDX-License-Identifier: AGPL-3.0-only
// A picture's thumbnail on its file card, and the full-screen viewer it opens. For an incoming file this is always
// and only the daemon's safe preview (CONTROL §14): the pixels it rebuilt with its own encoder after the check, the
// same "Safe preview" the Files section already shows — never the original file, and never before the check (a
// pending image keeps the ordinary card with "Preview after the check"). An outgoing image shows the window's own
// preview copy (`SentPreviews`), rebuilt from the bytes it sent: never the original path, which may be gone (a macOS
// screenshot's temporary file). An outgoing image without one (sent by an agent, or before this version) has no
// thumbnail: its card reads like any other file's.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import 'image_viewer.dart';

export 'image_viewer.dart';

/// By our own signature check once it is known, the sender's claim before that — enough to decide whether to try a
/// thumbnail; the bytes themselves are never trusted just because the name or the claimed type says "image".
bool isImageFile(FileInfo f) => (f.mime ?? f.senderMime).startsWith('image/');

/// Whether a thumbnail can even be asked for yet: an incoming file's safe preview exists only once the check has
/// run (`checked` or later); an outgoing file's preview copy right away (or once it is made).
bool imagePreviewReady(FileInfo f) => !f.incoming || (f.state != 'offered' && f.state != 'downloaded');

/// [f]'s card shows a thumbnail: an incoming picture (its safe preview, or the note before the check), or a sent one
/// the window kept a preview copy of.
bool showsThumbnail(AppModel m, FileInfo f) => isImageFile(f) && (f.incoming || m.hasSentPreview(f));

/// Decoded thumbnail/full-size bytes by file ID, so the viewer opening right after the thumbnail (or paging back to
/// an image already seen) never re-reads the safe preview or the local file. Cleared with the rest of the window's
/// file state ([AppModel.clearFiles] on lock); bounded in practice by how many distinct pictures one session opens.
final _imageBytesCache = <String, Uint8List>{};

/// For tests only: seeds the cache so a widget's `initState` never starts a real file read of its own — a load
/// kicked off synchronously while a frame is being pumped does not complete under `flutter_test` without
/// `tester.runAsync` wrapping the read itself, which `initState` has no way to do (see `image_thumbnail_test.dart`,
/// "an outgoing image's thumbnail…"). Production code never calls this.
@visibleForTesting
void primeImageBytesForTest(String fileId, Uint8List bytes) => _imageBytesCache[fileId] = bytes;

/// The bytes to show for [f]: the cache, then the safe preview (incoming) or the window's preview copy (outgoing);
/// `null` when none exists (not checked yet, the preview held nothing, no copy was kept). Never throws: a read error
/// or a daemon error is "no picture to show here", not a crash.
Future<Uint8List?> loadImageBytes(BuildContext context, FileInfo f) async {
  final cached = _imageBytesCache[f.id];
  if (cached != null) return cached;
  if (!imagePreviewReady(f)) return null;
  Uint8List? bytes;
  if (f.incoming) {
    try {
      final r = await AppScope.read(context).previewFile(f.id);
      final images = r.preview?.imagesPng ?? const [];
      bytes = images.isEmpty ? null : images.first;
      if (bytes == null) debugPrint('files: ${f.id.substring(0, 8)}: the daemon has no safe preview image');
    } on Object catch (e) {
      debugPrint('files: ${f.id.substring(0, 8)}: the safe preview: $e');
      bytes = null;
    }
  } else {
    bytes = await AppScope.read(context).sentPreviewBytes(f);
  }
  if (bytes != null) _imageBytesCache[f.id] = bytes;
  return bytes;
}

/// A rounded thumbnail on a file card: a spinner while the preview loads, a quiet placeholder before the check, the
/// picture once decoded. When there is no picture to show (no safe preview was made, the daemon refused, a file
/// accepted by preview.8 or earlier) it takes no space at all: the card's type icon and its Open and Show in Finder
/// stay, rather than a large box saying the preview failed. Tapping it opens the full-screen viewer ([gallery]: the
/// other images in the same conversation, oldest first, for Previous/Next — just this one file when omitted or it is
/// not in it). [gap] is the space under it while it shows something.
class ImageThumbnail extends StatefulWidget {
  const ImageThumbnail(this.f, {super.key, this.height = 220, this.gallery, this.gap = 0});
  final FileInfo f;
  final double height;
  final List<FileInfo>? gallery;
  final double gap;

  @override
  State<ImageThumbnail> createState() => _ImageThumbnailState();
}

class _ImageThumbnailState extends State<ImageThumbnail> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = loadImageBytes(context, widget.f);
  }

  @override
  void didUpdateWidget(covariant ImageThumbnail old) {
    super.didUpdateWidget(old);
    // A pending image's card rebuilds as the check moves along; only reload once there is something new to fetch.
    if (old.f.id != widget.f.id || old.f.state != widget.f.state) {
      _future = loadImageBytes(context, widget.f);
    }
  }

  void _open(Uint8List bytes) {
    final gallery = widget.gallery ?? const [];
    final list = gallery.any((x) => x.id == widget.f.id) ? gallery : [widget.f];
    final index = list.indexWhere((x) => x.id == widget.f.id);
    showImageViewer(context, [for (final f in list) viewerImageOf(f)], initialIndex: index < 0 ? 0 : index);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, s) {
        final done = s.connectionState == ConnectionState.done;
        final bytes = s.data;
        if (done && bytes == null && imagePreviewReady(widget.f)) {
          return SizedBox.shrink(key: Key('image-none-${widget.f.id.substring(0, 8)}'));
        }
        final Widget inner;
        if (!done) {
          inner = const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
        } else if (bytes == null) {
          inner = _ThumbPlaceholder(icon: Icons.image_outlined, label: l.filesImagePendingCheck);
        } else {
          inner = Semantics(
            button: true,
            label: l.filesImageOpen,
            image: true,
            child: InkWell(
              key: Key('image-thumb-${widget.f.id.substring(0, 8)}'),
              onTap: () => _open(bytes),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, e, _) {
                  debugPrint('files: ${widget.f.id.substring(0, 8)}: the picture did not decode: $e');
                  return _ThumbPlaceholder(icon: Icons.broken_image_outlined, label: l.filesPreviewImageError);
                },
              ),
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.only(bottom: widget.gap),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(XRadius.m),
            child: SizedBox(
              height: widget.height,
              width: double.infinity,
              child: ColoredBox(color: XColors.bg2, child: inner),
            ),
          ),
        );
      },
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 28, color: XColors.textMute),
          const SizedBox(height: 8),
          Text(label, style: XText.meta, textAlign: TextAlign.center),
        ]),
      );
}
