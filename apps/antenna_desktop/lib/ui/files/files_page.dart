// SPDX-License-Identifier: AGPL-3.0-only
// The Files section (x-control/3, CONTROL §14; D-UI-46): first what needs the owner (a file waiting for a decision, a
// held file with its warning) as full cards with their buttons; then what is downloading and being checked; then every
// other file, newest first, as compact rows or, for pictures, as a dense grid. Filters for Images, Files and Text, a
// search by name, and the same actions as in a conversation. The daemon stores everything; the window shows
// `files_pending --all` and `file` events.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/media.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../chat/chat_media.dart';
import '../updates/ready_banner.dart';
import '../widgets/section_page.dart';
import '../widgets/x_buttons.dart';
import 'file_card.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final _search = TextEditingController();

  /// The kind shown (`null`: all).
  MediaKind? _kind;

  /// Pictures as a grid of squares (the rest stay rows).
  bool _grid = true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final all = m.allFiles;
    final q = _search.text;
    final shown = searchFiles(all, query: q, kind: _kind);
    final awaiting = shown.where((f) => f.awaitingDecision).toList();
    final inProgress = shown.where((f) => f.incoming && (f.state == 'offered' || f.state == 'downloaded')).toList();
    final rest = shown.where((f) => !f.awaitingDecision && !inProgress.contains(f)).toList();
    final pictures = _grid ? rest.where((f) => fileLookOf(m, f) == FileLook.picture).toList() : <FileInfo>[];
    final rows = rest.where((f) => !pictures.contains(f)).toList();
    final gallery = pictureGallery(m, pictures);
    return SectionPage(
      title: l.filesTitle,
      subtitle: l.filesSubtitle,
      maxWidth: 1040,
      action: OutlinedButton.icon(
        key: const Key('files-refresh'),
        onPressed: m.refreshFiles,
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(l.filesRefresh),
      ),
      children: [
        // A verified release newer than this one, wherever its files are in the list below (D-UI-29).
        const UpdateReadyBanner(),
        if (!m.filesSupported)
          SectionCard(child: Text(l.filesUnsupported, style: XText.bodyDim))
        else if (all.isEmpty)
          SectionCard(
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
                child: Icon(Icons.inbox_outlined, size: 20, color: XColors.accent),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(l.filesEmpty, style: XText.bodyDim)),
            ]),
          )
        else ...[
          _Toolbar(
            search: _search,
            kind: _kind,
            grid: _grid,
            onSearch: () => setState(() {}),
            onKind: (k) => setState(() => _kind = k),
            onGrid: (g) => setState(() => _grid = g),
          ),
          const SizedBox(height: 16),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(q.trim().isEmpty ? l.mediaEmpty : l.mediaNoMatch(q.trim()),
                  key: const Key('files-empty-filter'), style: XText.bodyDim),
            ),
          if (awaiting.isNotEmpty)
            _Group(l.filesGroupAwaiting, awaiting.length, key: const Key('files-group-awaiting'), children: [
              for (final f in awaiting)
                Padding(padding: const EdgeInsets.only(bottom: 8), child: FileCard(f, showContact: true)),
            ]),
          if (inProgress.isNotEmpty)
            _Group(l.filesGroupInProgress, inProgress.length, key: const Key('files-group-progress'), children: [
              for (final f in inProgress)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FileRowCompact(f, showContact: true, maxWidth: double.infinity),
                ),
            ]),
          if (rest.isNotEmpty)
            _Group(l.filesGroupAll, rest.length, key: const Key('files-group-all'), children: [
              if (pictures.isNotEmpty) ...[
                _PictureGrid(pictures, gallery: gallery),
                const SizedBox(height: 12),
              ],
              for (final f in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: fileLookOf(m, f) == FileLook.card
                      ? FileCard(f, showContact: true)
                      : FileRowCompact(f, showContact: true, maxWidth: double.infinity),
                ),
            ]),
        ],
      ],
    );
  }
}

/// Search, the kind filter and the grid or list toggle.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.kind,
    required this.grid,
    required this.onSearch,
    required this.onKind,
    required this.onGrid,
  });
  final TextEditingController search;
  final MediaKind? kind;
  final bool grid;
  final VoidCallback onSearch;
  final ValueChanged<MediaKind?> onKind;
  final ValueChanged<bool> onGrid;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    Widget chip(MediaKind? k, String label) => ChoiceChip(
          key: Key('files-filter-${k?.name ?? 'all'}'),
          label: Text(label),
          selected: kind == k,
          showCheckmark: false,
          onSelected: (_) => onKind(k),
        );
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(
        width: 280,
        child: TextField(
          key: const Key('files-search'),
          controller: search,
          onChanged: (_) => onSearch(),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search_rounded, size: 18),
            hintText: l.mediaSearchHint,
          ),
        ),
      ),
      const SizedBox(width: 8),
      chip(null, l.filesFilterAll),
      chip(MediaKind.image, l.filesFilterImages),
      chip(MediaKind.file, l.filesFilterFiles),
      chip(MediaKind.text, l.filesFilterText),
      const SizedBox(width: 8),
      IconButton(
        key: const Key('files-view-grid'),
        tooltip: l.filesViewGrid,
        style: XButtons.icon(selected: grid),
        onPressed: () => onGrid(true),
        icon: const Icon(Icons.grid_view_rounded, size: 18),
      ),
      IconButton(
        key: const Key('files-view-list'),
        tooltip: l.filesViewList,
        style: XButtons.icon(selected: !grid),
        onPressed: () => onGrid(false),
        icon: const Icon(Icons.view_list_rounded, size: 18),
      ),
    ]);
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.count, {super.key, required this.children});
  final String title;
  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Text('${title.toUpperCase()} · $count', style: XText.overline),
          ),
          ...children,
        ]),
      );
}

/// Pictures as small squares, as many as fit a row.
class _PictureGrid extends StatelessWidget {
  const _PictureGrid(this.files, {required this.gallery});
  final List<FileInfo> files;
  final List<FileInfo> gallery;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        const gap = 6.0;
        final n = (box.maxWidth / 124).floor().clamp(3, 10);
        final side = (box.maxWidth - gap * (n - 1)) / n;
        return Wrap(
          key: const Key('files-grid'),
          spacing: gap,
          runSpacing: gap,
          children: [for (final f in files) PictureSquare(f, side: side, gallery: gallery)],
        );
      });
}
