// SPDX-License-Identifier: AGPL-3.0-only
// A chat's Media and files (D-UI-46), as a messenger's shared media: Images as a grid of squares, Files and Text as
// compact rows, newest first, with a search by name. Opened from the conversation's header, its menu and the contact
// card. In a chat with one of the contact's agents it shows that chat's files first, and everything exchanged with the
// contact one click away. Every picture is the safe preview or the window's preview copy (`chat_media.dart`), and each
// file has the same actions as in the conversation.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/media.dart';
import '../../state/threads.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../chat/chat_media.dart';
import '../home/chat_menu.dart' show chatTitle;
import '../widgets/dialog_shell.dart';

/// Open the Media and files of the chat [k] with [c] (the chat on screen when omitted).
Future<void> showMediaAndFiles(BuildContext context, ContactInfo c, {ThreadKey? k}) => showXDialog<void>(
    context, (_) => MediaAndFilesDialog(c, k: k ?? AppScope.read(context).openThreadOf(c.linkId)));

/// The files of [c]'s chat [k]: those whose offer is a message of that chat, as far as its history is loaded here.
/// The person chat also has the files the contact's agents and this side's agents exchanged with nobody named.
List<FileInfo> filesOfChat(AppModel m, ContactInfo c, ThreadKey k) {
  final ids = {for (final e in m.chatOf(c.linkId)) if (threadOf(e) == k) e.id};
  return [for (final f in m.filesOfLink(c.linkId)) if (f.messageId != null && ids.contains(f.messageId)) f];
}

class MediaAndFilesDialog extends StatefulWidget {
  const MediaAndFilesDialog(this.c, {super.key, required this.k});
  final ContactInfo c;
  final ThreadKey k;

  @override
  State<MediaAndFilesDialog> createState() => _MediaAndFilesDialogState();
}

class _MediaAndFilesDialogState extends State<MediaAndFilesDialog> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  final _search = TextEditingController();

  /// Only this chat's files (a chat with an agent), or everything exchanged with the contact.
  late bool _thisChat = !widget.k.isPerson;

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final c = widget.c;
    final source = _thisChat ? filesOfChat(m, c, widget.k) : m.filesOfLink(c.linkId);
    final q = _search.text;
    final images = searchFiles(source, query: q, kind: MediaKind.image);
    final files = searchFiles(source, query: q, kind: MediaKind.file);
    final texts = searchFiles(source, query: q, kind: MediaKind.text);
    final gallery = pictureGallery(m, images);
    final height = (MediaQuery.sizeOf(context).height * 0.72).clamp(360.0, 720.0);
    return XDialogShell(
      key: const Key('media-dialog'),
      title: l.mediaTitle(chatTitle(l, m, c, widget.k)),
      icon: Icons.perm_media_outlined,
      width: 760,
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.commonClose))],
      child: SizedBox(
        height: height,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('media-search'),
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  hintText: l.mediaSearchHint,
                ),
              ),
            ),
            if (!widget.k.isPerson) ...[
              const SizedBox(width: 12),
              ChoiceChip(
                key: const Key('media-scope-chat'),
                label: Text(l.mediaScopeThisChat),
                selected: _thisChat,
                showCheckmark: false,
                onSelected: (_) => setState(() => _thisChat = true),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                key: const Key('media-scope-all'),
                label: Text(l.mediaScopeAll(c.label)),
                selected: !_thisChat,
                showCheckmark: false,
                onSelected: (_) => setState(() => _thisChat = false),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(key: const Key('media-tab-images'), text: l.mediaTabImages(images.length)),
              Tab(key: const Key('media-tab-files'), text: l.mediaTabFiles(files.length)),
              Tab(key: const Key('media-tab-text'), text: l.mediaTabText(texts.length)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TabBarView(controller: _tabs, children: [
              _Grid(images, gallery: gallery, query: q),
              _Rows(files, query: q),
              _Rows(texts, query: q),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// What an empty tab says: nothing yet, or nothing under the search.
class _Empty extends StatelessWidget {
  const _Empty(this.query);
  final String query;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(
          query.trim().isEmpty ? context.l.mediaEmpty : context.l.mediaNoMatch(query.trim()),
          key: const Key('media-empty'),
          style: XText.bodyDim,
        ),
      );
}

/// Pictures as squares, as many as fit a row.
class _Grid extends StatelessWidget {
  const _Grid(this.files, {required this.gallery, required this.query});
  final List<FileInfo> files;
  final List<FileInfo> gallery;
  final String query;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return _Empty(query);
    return LayoutBuilder(builder: (context, box) {
      const gap = 4.0;
      final n = (box.maxWidth / 132).floor().clamp(3, 8);
      final side = (box.maxWidth - gap * (n - 1)) / n;
      return GridView.builder(
        key: const Key('media-grid'),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: n, mainAxisSpacing: gap, crossAxisSpacing: gap),
        itemCount: files.length,
        itemBuilder: (context, i) => PictureSquare(files[i], side: side, gallery: gallery),
      );
    });
  }
}

/// Files as compact rows.
class _Rows extends StatelessWidget {
  const _Rows(this.files, {required this.query});
  final List<FileInfo> files;
  final String query;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return _Empty(query);
    return ListView.separated(
      itemCount: files.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => FileRowCompact(files[i], maxWidth: double.infinity),
    );
  }
}
