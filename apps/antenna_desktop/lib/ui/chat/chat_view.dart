// SPDX-License-Identifier: AGPL-3.0-only
// Chat with a link: header (level, the "Secure" indicator with the E2E, PQ and history facts behind it, network mode,
// presence), a timeline from the daemon's history (paged) and subscription events, and the composer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/approval_finish.dart';
import '../../state/drafts.dart';
import '../../state/format.dart';
import '../../state/long_text.dart';
import '../../state/media.dart';
import '../../state/messages.dart';
import '../../state/threads.dart';
import '../../state/trust.dart';
import '../../theme/antenna_mark.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../approvals/approvals_view.dart';
import '../approvals/approver_notes.dart';
import '../files/file_card.dart';
import '../files/file_drop.dart';
import '../files/media_files.dart';
import '../home/chat_menu.dart';
import '../pairing/pairing_dialogs.dart';
import '../security/owner_confirm.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/agent_logo.dart';
import '../widgets/badges.dart';
import '../widgets/x_buttons.dart';
import 'bubble_text.dart';
import 'chat_media.dart';
import 'composer.dart';
import 'history_bar.dart';
import 'message_bubble.dart';
import 'secure_indicator.dart';
import 'stream_bubble.dart';
import 'thread_bar.dart';

class ChatView extends StatelessWidget {
  const ChatView({super.key, this.cardVisible = false, this.onToggleCard});

  final bool cardVisible;
  final VoidCallback? onToggleCard;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final c = m.selected;
    return ColoredBox(
      color: XColors.bg1,
      child: c == null
          ? const _NoSelection()
          : Column(children: [
              ChatHeader(c, cardVisible: cardVisible, onToggleCard: onToggleCard),
              const Divider(height: 1),
              ThreadBar(c),
              HistoryBanners(c),
              // Files dropped on the composer go to this link too.
              Expanded(
                child: FileDropZone(c,
                    child: Column(children: [
                      // One list per chat: each keeps where the person was reading it (drafts.dart).
                      Expanded(
                          child: _Messages(c, key: ValueKey('messages-${draftKey(c.linkId, m.openThreadOf(c.linkId))}'))),
                      if (c.history?.sendBlocked ?? false)
                        _ReadOnlyBar(c)
                      else
                        // One composer per chat: its text, files and choices are that chat's draft (drafts.dart).
                        Composer(key: ValueKey('composer-${draftKey(c.linkId, m.openThreadOf(c.linkId))}')),
                    ])),
              ),
            ]),
    );
  }
}

class ChatHeader extends StatelessWidget {
  const ChatHeader(this.c, {super.key, this.cardVisible = false, this.onToggleCard, this.presence});
  final ContactInfo c;
  final bool cardVisible;
  final VoidCallback? onToggleCard;

  /// For mockups: presence is set explicitly.
  final bool? presence;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.maybeOf(context);
    final presence = this.presence ?? m?.presenceOf(c);
    final tracked = presence != null;
    // Opens the card; `null` once it is already open (nothing to do), the same restriction the indicator's own
    // "Contact card" link uses. The info button keeps working even then (it also hides the card).
    final openCard = onToggleCard != null && !cardVisible ? onToggleCard : null;
    // The open chat (D-UI-32): the person chat is the contact itself; a chat with one of its agents carries the
    // agent's picture and the chat's name, and under a local name, whose agent it is
    final k = m?.openThreadOf(c.linkId) ?? ThreadKey.person;
    final title = m == null ? c.label : chatTitle(context.l, m, c, k);
    final renamed = !k.isPerson && m?.chatName(c.linkId, k) != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
      child: Row(children: [
        _HeaderTap(
          key: const Key('chat-header-avatar'),
          onTap: openCard,
          tooltip: context.l.chatShowCard,
          borderRadius: BorderRadius.circular(20),
          child: k.isPerson
              ? XAvatar(c.label,
                  size: 40,
                  presence: presence,
                  agent: c.peerKind == 'agent',
                  picture: m?.pictureOfContact(c.linkId))
              : AgentAvatar(AgentRef(k.agent!, contact: c.label, linkId: c.linkId), size: 40),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _HeaderTap(
              key: const Key('chat-header-name'),
              onTap: openCard,
              tooltip: context.l.chatShowCard,
              borderRadius: BorderRadius.circular(XRadius.s),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(title, overflow: TextOverflow.ellipsis, style: XText.h2)),
                const SizedBox(width: 8),
                TrustBadge(c.trust, size: 18, showName: true, key: const Key('chat-header-trust')),
              ]),
            ),
            if (renamed)
              Text(context.l.chatAgentTitle(c.label, k.agent!),
                  key: const Key('chat-header-agent'), style: XText.meta.copyWith(color: XColors.textDim)),
            const SizedBox(height: 4),
            // One "Secure" indicator with its details (reference v3), then the quiet facts: network mode, presence,
            // the queue.
            Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SecureIndicator(c, onDetails: openCard),
              _Meta(
                c.netMode == 'relay_only' ? Icons.cell_tower_outlined : Icons.swap_horiz,
                netModeLabel(context.l, c.netMode),
                netModeHint(context.l, c.netMode),
              ),
              if (tracked)
                _Meta(
                  Icons.circle,
                  presence ? context.l.commonOnline : context.l.commonOffline,
                  context.l.chatPresenceTooltip,
                  color: presence ? XColors.ok : XColors.textMute,
                  iconSize: 8,
                )
              else
                _Meta(Icons.visibility_off_outlined, context.l.chatPresenceHidden,
                    context.l.chatPresenceHiddenTooltip),
              if (c.outbox > 0)
                _Meta(Icons.schedule, context.l.chatQueued(c.outbox), context.l.chatQueuedTooltip, color: XColors.warn),
            ]),
          ]),
        ),
        if (m != null)
          IconButton(
            key: const Key('chat-media'),
            tooltip: context.l.chatMenuMedia,
            onPressed: () => showMediaAndFiles(context, c, k: k),
            icon: Icon(Icons.perm_media_outlined, size: 20, color: XColors.textDim),
          ),
        if (m != null) ChatMenuButton(c, k),
        if (onToggleCard != null)
          IconButton(
            key: const Key('card-toggle'),
            tooltip: cardVisible ? context.l.chatHideCard : context.l.chatShowCard,
            onPressed: onToggleCard,
            style: XButtons.icon(selected: cardVisible),
            icon: const Icon(Icons.info_outline_rounded, size: 20),
          ),
      ]),
    );
  }
}

/// Wraps the avatar and the name with the same "open the contact card" tap the info button has, so both reach it:
/// a plain child (no hover, no cursor) once there is nothing to open ([onTap] `null`).
class _HeaderTap extends StatelessWidget {
  const _HeaderTap(
      {super.key, required this.onTap, required this.tooltip, required this.borderRadius, required this.child});
  final VoidCallback? onTap;
  final String tooltip;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: borderRadius,
        child: InkWell(onTap: onTap, borderRadius: borderRadius, child: child),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text, this.tip, {this.color, this.iconSize = 13});
  final IconData icon;
  final String text;
  final String tip;
  final Color? color;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: iconSize, color: color ?? XColors.textMute),
          const SizedBox(width: 4),
          Text(text, style: XText.meta.copyWith(color: color ?? XColors.textDim)),
        ]),
      );
}

class _Messages extends StatefulWidget {
  const _Messages(this.c, {super.key});
  final ContactInfo c;

  @override
  State<_Messages> createState() => _MessagesState();
}

class _MessagesState extends State<_Messages> {
  final _scroll = ScrollController();

  /// Wraps whatever row is currently newest (bottom-most): a handle to measure its real rendered height directly
  /// ([_compensate]), rather than trust the sliver's own `maxScrollExtent` for the delta — on a short list well
  /// short of a screenful, `RenderSliverList` answers that from an interpolated estimate of children outside the
  /// cache area, not their exact laid-out size, which was off by a few percent in practice (seen failing in
  /// `chat_scroll_test.dart` before this: jump buttons, the position still drifted a handful of pixels per message).
  final _bottomBox = GlobalKey();

  /// Close enough to `pixels == 0` to count as "at the bottom" (float drift from [_compensate]'s `jumpTo`).
  static const _bottomSlop = 24.0;

  /// The bottom row's rendered height as of the last frame this state measured; `null` before the first measurement.
  double? _lastBottomHeight;

  /// Identity of the bottom row as of the last measurement (its `ValueKey`'s value: `chat-row-<message id>` or
  /// `chat-row-stream-<stream id>`): changing identity means a *different* row is now newest (insert its full
  /// height); the same identity with a different height means that same row grew in place (a stream, a decoding
  /// image preview — compensate by the difference, not the whole new height).
  Object? _lastBottomIdentity;

  /// The newest entry's id (plus the count, in case a same-id edit is ever added later): distinct from
  /// [_lastBottomIdentity], which also changes for a stream bubble opening — only an actual history entry arriving
  /// counts toward the jump button, never a stream merely starting or growing.
  String? _lastBottomSignature;

  /// Pagination (`loadHistory(older: true)`) also grows the bottom-less far end, which needs no compensation
  /// (nothing before the reader's position moved); [_wasLoadingOlder] (the previous frame's value) tells the two
  /// apart, since the model's own `loadingOlder` has already gone back to `false` by the time the older page's rows
  /// are actually in the tree (`AppModel.loadHistory`'s `finally`). Pagination never touches the bottom row anyway,
  /// so in practice [_lastBottomIdentity] alone already excludes it; this stays as a second, explicit guard.
  bool _wasLoadingOlder = false;

  /// New messages that arrived while scrolled away from the bottom; shown on the jump button, cleared by using it or
  /// by reaching the bottom by hand.
  int _newSinceScrolled = 0;

  bool get _atBottom => !_scroll.hasClients || _scroll.position.pixels <= _bottomSlop;

  /// The chat this list shows (the chat view keys a list per chat), and where the person had left it.
  late final String _link = widget.c.linkId;
  late final ThreadKey _chat;
  ReadingPosition? _left;

  /// The first message that came while the person was away: a "New messages" line stands above it.
  String? _firstNewId;

  /// Each message row's key, to find where it is on screen (the reading position).
  final _rowKeys = <String, GlobalKey>{};
  final _listKey = GlobalKey();
  Timer? _keepTimer;
  late final AppModel _m;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _m = AppScope.read(context);
    _chat = _m.openThreadOf(_link);
    _left = _m.readingPositionOf(_link, _chat);
    final entries = _m.visibleChat(_link);
    final seen = _left?.newestId == null ? -1 : entries.indexWhere((e) => e.id == _left!.newestId);
    if (seen >= 0 && seen < entries.length - 1) {
      _firstNewId = entries[seen + 1].id;
      _newSinceScrolled = entries.length - 1 - seen;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  /// Back where the person left: the end when they were there and nothing came; otherwise the same message at the
  /// same height (the last one read, when they were at the end and more came).
  void _restore() {
    final left = _left;
    if (!mounted || left == null || !_scroll.hasClients) return;
    if (left.atEnd && _firstNewId == null) return;
    final id = left.anchorId;
    final top = id == null ? null : _topOf(id);
    if (top == null) return;
    final p = _scroll.position;
    // A reversed list: more pixels move everything down.
    p.jumpTo((p.pixels + left.anchorTop - top).clamp(0.0, p.maxScrollExtent));
  }

  /// The top of message [id]'s row below the top of the list's view; `null` when it is not laid out.
  double? _topOf(String id) {
    final row = _rowKeys[id]?.currentContext?.findRenderObject();
    final list = _listKey.currentContext?.findRenderObject();
    if (row is! RenderBox || list is! RenderBox || !row.attached || !list.attached || !row.hasSize) return null;
    return row.localToGlobal(Offset.zero, ancestor: list).dy;
  }

  /// Where the person reads now: the message at the top of the view (the one the top edge cuts, or the first below
  /// it), at the end or not, and the newest message.
  void _keepPosition() {
    if (!mounted || !_scroll.hasClients) return;
    final entries = _m.visibleChat(_link);
    if (entries.isEmpty) return;
    final list = _listKey.currentContext?.findRenderObject();
    final height = list is RenderBox && list.hasSize ? list.size.height : 0.0;
    String? anchor;
    var anchorTop = 0.0;
    for (final e in entries.reversed) {
      final top = _topOf(e.id);
      if (top == null) continue;
      if (top <= 0 || anchor == null) {
        if (top < height) {
          anchor = e.id;
          anchorTop = top;
        }
      }
      if (top <= 0) break;
    }
    // Nothing measurable (the list is already leaving the screen): what was kept last stands.
    if (anchor == null) return;
    _m.keepReadingPosition(_link, _chat,
        ReadingPosition(atEnd: _atBottom, newestId: entries.last.id, anchorId: anchor, anchorTop: anchorTop));
  }

  void _keepSoon() {
    _keepTimer?.cancel();
    _keepTimer = Timer(const Duration(milliseconds: 150), _keepPosition);
  }

  @override
  void deactivate() {
    // Leaving the chat: what was kept 150 ms ago may be older than the last scroll.
    _keepTimer?.cancel();
    _keepPosition();
    super.deactivate();
  }

  GlobalKey _rowKey(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);

  void _onScroll() {
    final p = _scroll.position;
    // The timeline is reversed, so the "top" is maxScrollExtent; load the older page ahead of time.
    if (p.pixels > p.maxScrollExtent - 240) {
      final m = AppScope.read(context);
      final t = m.pagingOf(widget.c.linkId);
      if (!t.reachedStart && !t.loadingOlder) m.loadHistory(widget.c.linkId, older: true);
    }
    // Reaching the bottom by hand: the reader has seen the tail, so the jump button and its count go away.
    if (_atBottom && _newSinceScrolled != 0) setState(() => _newSinceScrolled = 0);
    _keepSoon();
  }

  @override
  void dispose() {
    _keepTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  double? get _bottomHeight {
    final box = _bottomBox.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.height : null;
  }

  /// Keeps whatever the reader is looking at exactly where it is when the list grows below/at their position (a new
  /// message, a streaming bubble, an image whose preview just finished decoding): a reversed `ListView` anchors new
  /// content at `pixels == 0`, so without this, every such change shifts everything above it by its own height. At
  /// the bottom already, nothing to compensate: `pixels == 0` already shows the new content, which is the expected
  /// "it scrolls into view" behaviour. Pagination at the far end is exempted (see [_wasLoadingOlder]).
  void _compensate(Object? bottomIdentity, String bottomSignature, bool loadingOlder, {bool mineNew = false}) {
    if (!_scroll.hasClients) return;
    // The person's own new message: the end, wherever they were reading (as in any messenger).
    if (mineNew && bottomSignature != _lastBottomSignature && _lastBottomSignature != null) {
      _scroll.jumpTo(0);
      _lastBottomHeight = _bottomHeight;
      _lastBottomIdentity = bottomIdentity;
      _lastBottomSignature = bottomSignature;
      _wasLoadingOlder = loadingOlder;
      if (_newSinceScrolled != 0 || _firstNewId != null) {
        setState(() {
          _newSinceScrolled = 0;
          _firstNewId = null;
        });
      }
      _keepSoon();
      return;
    }
    final height = _bottomHeight;
    if (height != null && _lastBottomHeight != null && !loadingOlder && !_wasLoadingOlder) {
      final sameRow = bottomIdentity != null && bottomIdentity == _lastBottomIdentity;
      // A different row now sits at the bottom: its own full height was inserted. The same row, taller: only the
      // difference was.
      final grew = sameRow ? height - _lastBottomHeight! : height;
      if (grew > 0.5 && !_atBottom) {
        _scroll.jumpTo(_scroll.position.pixels + grew);
      }
    }
    if (bottomSignature != _lastBottomSignature && _lastBottomSignature != null && !_atBottom && mounted) {
      setState(() => _newSinceScrolled++);
    }
    _lastBottomHeight = height;
    _lastBottomIdentity = bottomIdentity;
    _lastBottomSignature = bottomSignature;
    _wasLoadingOlder = loadingOlder;
    _keepSoon();
  }

  Future<void> _jumpToBottom() async {
    if (_scroll.hasClients) await _scroll.animateTo(0, duration: XMotion.normal, curve: Curves.easeOut);
    if (mounted) setState(() => _newSinceScrolled = 0);
  }

  /// Message rows get a key of their own (where each one is, for the reading position), and the first message that
  /// came while the person was away gets the "New messages" line above it.
  List<Widget> _withRowKeys(List<Widget> rows, List<ChatEntry> entries) {
    final ids = {for (final e in entries) e.id};
    final out = <Widget>[];
    for (final r in rows) {
      final k = r.key;
      final id = k is ValueKey<String> && k.value.startsWith('chat-row-') ? k.value.substring(9) : null;
      if (id != null && ids.contains(id) && r is KeyedSubtree) {
        if (id == _firstNewId) out.add(_NewMessagesLine(key: ValueKey('chat-row-new-$id')));
        out.add(KeyedSubtree(key: k, child: KeyedSubtree(key: _rowKey(id), child: r.child)));
      } else {
        out.add(r);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final entries = m.visibleChat(widget.c.linkId);
    final rows = _withRowKeys(buildTimeline(context, m, widget.c), entries);
    final bottomSignature = '${entries.length}:${entries.isEmpty ? '' : entries.last.id}';
    final newest = entries.lastOrNull;
    final mineNew = newest != null && newest.outgoing && newest.viaAgent == null && newest.seq == null;
    final loadingOlder = m.pagingOf(widget.c.linkId).loadingOlder;
    Object? bottomIdentity;
    if (rows.isNotEmpty) {
      bottomIdentity = rows.last.key is ValueKey ? (rows.last.key! as ValueKey).value : null;
      rows[rows.length - 1] = KeyedSubtree(key: _bottomBox, child: rows.last);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _compensate(bottomIdentity, bottomSignature, loadingOlder, mineNew: mineNew);
    });
    return LayoutBuilder(builder: (context, box) => ChatViewHeight(
      height: box.maxHeight.isFinite ? box.maxHeight : MediaQuery.sizeOf(context).height,
      child: Stack(children: [
      // The list's own box (its key), to measure where message rows are (the reading position).
      KeyedSubtree(key: _listKey, child: ListView(
        key: const Key('chat-messages'),
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
        // A reader scrolled well away from the bottom is, by construction, past Flutter's default ~250 px cache
        // window: short of this, `RenderSliverList` answers `maxScrollExtent` (and any off-screen row's size) from
        // an interpolated estimate of the rows it has not laid out, not their real height — a few percent off in
        // practice, which was exactly the gap `_compensate` could not close (seen failing in `chat_scroll_test.dart`
        // without this: the position still drifted a handful of pixels on every arrival). A page is 50 messages
        // (`AppModel.pageSize`); this comfortably covers a reader who scrolled up through several pages at once.
        scrollCacheExtent: const ScrollCacheExtent.pixels(50000),
        children: rows.reversed.toList(),
      )),
      if (_newSinceScrolled > 0)
        Positioned(
          right: 20,
          bottom: 12,
          child: _JumpToBottom(count: _newSinceScrolled, onTap: _jumpToBottom),
        ),
    ])));
  }
}

/// Above the first message that came while the person was away from the chat.
class _NewMessagesLine extends StatelessWidget {
  const _NewMessagesLine({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(children: [
          Expanded(child: Divider(color: XColors.accent.withValues(alpha: 0.5), height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(context.l.chatNewMessagesLine, style: XText.meta.copyWith(color: XColors.accent)),
          ),
          Expanded(child: Divider(color: XColors.accent.withValues(alpha: 0.5), height: 1)),
        ]),
      );
}

/// New messages arrived while the reader had scrolled away from the bottom: a round button over the timeline, with
/// their count, that scrolls to the newest on tap (reference v3's primary button colour, round).
class _JumpToBottom extends StatelessWidget {
  const _JumpToBottom({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = context.l.chatJumpToLatest(count);
    return Semantics(
      button: true,
      label: label,
      child: Stack(
        key: const Key('chat-jump-bottom'),
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          IconButton(
            key: const Key('chat-jump-bottom-tap'),
            tooltip: label,
            onPressed: onTap,
            style: XButtons.primary().copyWith(
              shape: const WidgetStatePropertyAll(CircleBorder()),
              minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              elevation: const WidgetStatePropertyAll(2),
            ),
            icon: Icon(Icons.arrow_downward_rounded, size: 22, color: XColors.onAccent),
          ),
          Positioned(right: -4, top: -4, child: CountBubble(count)),
        ],
      ),
    );
  }
}

/// Timeline rows: start of history, day dividers, messages, UI notes. With threads (v6, D-UI-18) only the open thread
/// under its filter; in a link where agents take part, every group of bubbles is signed by its author.
List<Widget> buildTimeline(BuildContext context, AppModel m, ContactInfo c) {
  // The open chat's pages when the daemon reads by chat (v7), the whole link's otherwise
  final t = m.pagingOf(c.linkId);
  final entries = m.visibleChat(c.linkId);
  final now = m.now();
  final signed = m.authorsShown(c.linkId);
  // Every picture in this conversation, oldest first, so an opened viewer can page through the others with it.
  final imageGallery = pictureGallery(m, m.filesOfLink(c.linkId));
  final rows = <Widget>[KeyedSubtree(key: const ValueKey('chat-row-head'), child: _HistoryHead(c, t))];
  if (t.loaded && t.reachedStart && entries.isEmpty && m.chatOf(c.linkId).isNotEmpty) {
    rows.add(const ThreadEmpty());
  }
  DateTime? day;
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final d = DateTime(e.at.year, e.at.month, e.at.day);
    if (day != d) {
      day = d;
      rows.add(DayDivider(dayLabel(context.l, e.at, now), key: ValueKey('chat-row-day-$d')));
    }
    final prev = i > 0 ? entries[i - 1] : null;
    final grouped = continuesGroup(prev, e, prevIsFile: prev != null && m.fileByMessage(prev.id) != null);
    final file = m.fileByMessage(e.id);
    // Pictures sent one after another, on the same day, form one album (D-UI-46): the row takes the first one's id.
    if (file != null && e.kind != EntryKind.local && e.kind != EntryKind.receipt && albumable(m, file)) {
      final album = [file];
      while (album.length < albumMax && i + album.length < entries.length) {
        final next = entries[i + album.length];
        final nf = m.fileByMessage(next.id);
        if (nf == null || !albumable(m, nf) || !joinsAlbum(album.last, nf)) break;
        if (DateTime(next.at.year, next.at.month, next.at.day) != d) break;
        album.add(nf);
      }
      if (album.length > 1) {
        rows.add(KeyedSubtree(
          key: ValueKey('chat-row-${e.id}'),
          child: AlbumRow(album, outgoing: e.outgoing, gallery: imageGallery),
        ));
        i += album.length - 1;
        continue;
      }
    }
    // A stable identity per row (its message id), so a reversed, rebuilt-from-scratch ListView matches each
    // existing bubble to itself instead of to whatever now sits at its old index: without it, prepending the
    // newest message at index 0 shifts every later row's widget identity by one, and Flutter's sliver geometry
    // cache (built against the old identities) misjudges the scroll compensation of `_MessagesState.compensate`.
    rows.add(KeyedSubtree(
      key: ValueKey('chat-row-${e.id}'),
      child: switch (e.kind) {
        EntryKind.local => LocalNote(e),
        EntryKind.receipt => ReceiptLine(e, contact: c.label),
        _ when file != null => FileRow(file, outgoing: e.outgoing, imageGallery: imageGallery),
        _ => MessageBubble(
            e,
            contact: c.label,
            peerAgents: [for (final a in c.agents) if (a.state != 'revoked') a.name],
            grouped: grouped,
            signed: signed,
            endedInterrupted: m.interruptedFinals.contains(e.id),
            onApproveAndSend: e.approvalId == null ? null : () => _approveAndSend(context, e),
            onRetry: e.delivery == Delivery.failed && e.approvalId == null && e.seq == null
                ? () => AppScope.read(context).send(e.text, retry: e)
                : null,
            onSendAsFile: e.delivery == Delivery.failed && e.seq == null && refusedAsTooLong(e)
                ? () => AppScope.read(context).sendTextAsFile(c.linkId, e.text, failed: e)
                : null,
          ),
      },
    ));
  }
  // Sends the daemon is still preparing or has held (secret → approval).
  for (final o in m.outgoingOf(c.linkId)) {
    rows.add(Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(alignment: Alignment.centerRight, child: OutgoingFileCard(o)),
    ));
  }
  // Live bubbles of streams still being written (or waiting for the final message) go at the bottom of the timeline.
  final wakeAgent = m.wakeRuleOf(c.linkId)?.agent;
  for (final st in m.streamsOf(c.linkId, thread: m.openThreadOf(c.linkId))) {
    rows.add(StreamBubble(st,
        key: ValueKey('chat-row-stream-${st.streamId}'), contact: c.label, agentName: st.viaAgent ?? wakeAgent));
  }
  // An agent waiting for the owner's approval about this contact (D-84): the card stands where the owner looks, last
  // in the conversation, until it is decided or runs out of time.
  // Several from one agent: its last card, the one nearest the input line, offers "Approve all from this agent" (one
  // password, v6).
  // Approved, and the daemon finishes the action itself (x-control/6): the card keeps its place and its key, so it
  // changes in place, until the daemon reports the outcome; a failure stays until the owner dismisses it.
  // Decided by an approver agent in the owner's place (CONTROL §31): its own card, which also carries the finishing
  // state, until the owner dismisses it.
  final pending = m.approvalsFor(c.linkId);
  final decided = m.decidedFor(c.linkId);
  final cards = <(ApprovalInfo, ApprovalFinish?)>[
    for (final a in pending) (a, null),
    for (final f in m.finishingFor(c.linkId))
      if (!m.decidedByApprovers.containsKey(f.approval.id)) (f.approval, f),
    for (final a in decided) (a, m.finishing[a.id]),
  ]..sort((x, y) => x.$1.createdMs.compareTo(y.$1.createdMs));
  for (final (a, finish) in cards) {
    if (a.decidedBy != null && !a.pending) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: DecidedCard(a, key: ValueKey('chat-decided-card-${a.id}'), inChat: true, finish: finish),
          ),
        ),
      ));
      continue;
    }
    final same = [for (final x in pending) if (x.requester == a.requester) x];
    rows.add(Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ApprovalCard(
            a,
            key: ValueKey('chat-approval-card-${a.id}'),
            inChat: true,
            finish: finish,
            sameAgent: finish == null && same.length > 1 && identical(same.last, a) ? same : null,
          ),
        ),
      ),
    ));
  }
  return rows;
}

/// A file in the timeline (incoming on the left, sent on the right), as [fileLookOf] says: the picture itself, a
/// compact row, or the full card while a decision needs something read first.
class FileRow extends StatelessWidget {
  const FileRow(this.f, {super.key, required this.outgoing, this.imageGallery});
  final FileInfo f;
  final bool outgoing;

  /// The conversation's pictures (`buildTimeline`), for the viewer's Previous/Next.
  final List<FileInfo>? imageGallery;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final gallery = imageGallery ?? [f];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: switch (fileLookOf(m, f)) {
          FileLook.picture => ChatPicture(f, gallery: gallery),
          FileLook.row => FileRowCompact(f),
          FileLook.card => FileCard(f, compact: true, imageGallery: gallery),
        },
      ),
    );
  }
}

/// Pictures sent together, as one album in the timeline.
class AlbumRow extends StatelessWidget {
  const AlbumRow(this.files, {super.key, required this.outgoing, required this.gallery});
  final List<FileInfo> files;
  final bool outgoing;
  final List<FileInfo> gallery;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
          child: ChatAlbum(files, gallery: gallery),
        ),
      );
}

/// The daemon's secret scanner held a send: the owner approves it (with the password) and sends with `approval_id`.
Future<void> _approveAndSend(BuildContext context, ChatEntry e) async {
  final m = AppScope.read(context);
  final id = e.approvalId!;
  final a = m.approvals[id];
  final (done, err) = await confirmApproval(
    context,
    id,
    action: context.l.chatApproveSecretAction,
    detail: a == null ? null : context.l.chatApproveSecretDetail(a.reasons.join(', '), a.fingerprint),
    cli: 'antenna approve $id',
  );
  if (!done) {
    if (err != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
    }
    return;
  }
  await m.send(e.text, approvalId: id, retry: e);
}

class _HistoryHead extends StatelessWidget {
  const _HistoryHead(this.c, this.t);
  final ContactInfo c;
  final ChatPage? t;

  @override
  Widget build(BuildContext context) {
    final created = DateTime.fromMillisecondsSinceEpoch(c.createdMs);
    final Widget child;
    if (t == null || !t!.loaded) {
      child = Text(context.l.chatLoadingHistory, style: XText.monoSmall);
    } else if (!t!.reachedStart) {
      child = TextButton.icon(
        onPressed: t!.loadingOlder ? null : () => AppScope.read(context).loadHistory(c.linkId, older: true),
        icon: const Icon(Icons.expand_less, size: 16),
        label: Text(t!.loadingOlder ? context.l.commonLoading : context.l.chatEarlier, style: XText.monoSmall.copyWith(color: XColors.accent)),
      );
    } else {
      child = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: XColors.bg2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.link, size: 13, color: XColors.textMute),
          const SizedBox(width: 8),
          Text(
            '${context.l.chatHistoryStart(context.l.dateAt(formatDate(context.l, created), hhmm(created)))} · '
            '${c.role == 'inviter' ? context.l.commonYouInvited : context.l.commonYouJoined}',
            style: XText.meta,
          ),
        ]),
      );
    }
    return Padding(padding: const EdgeInsets.only(bottom: 8, top: 4), child: Center(child: child));
  }
}

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const AntennaAppIcon(size: 64),
          const SizedBox(height: 24),
          Text(m.contacts.isEmpty ? context.l.chatFirstContact : context.l.chatSelectContact, style: XText.h1),
          const SizedBox(height: 8),
          Text(
            context.l.chatNoSelectionBody,
            textAlign: TextAlign.center,
            style: XText.body.copyWith(color: XColors.textDim),
          ),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            FilledButton.icon(
              onPressed: () => showInviteDialog(context),
              icon: const Icon(Icons.qr_code_2, size: 18),
              label: Text(context.l.commonInvite),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => showJoinDialog(context),
              icon: const Icon(Icons.link, size: 18),
              label: Text(context.l.commonJoin),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// A read-only link (history mismatch or rollback): the reason is shown instead of the composer.
class _ReadOnlyBar extends StatelessWidget {
  const _ReadOnlyBar(this.c);
  final ContactInfo c;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(24, 4, 24, 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: xPanel(fill: XColors.bg2, radius: XRadius.l, border: XColors.line),
        child: Row(children: [
          Icon(Icons.lock_outline, size: 16, color: XColors.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              (c.history?.rolledBack ?? false) || (c.history?.peerRolledBack ?? false)
                  ? context.l.chatReadOnlyRekey
                  : context.l.chatReadOnlyMismatch,
              style: XText.bodyDim,
            ),
          ),
        ]),
      );
}
