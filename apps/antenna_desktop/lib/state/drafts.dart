// SPDX-License-Identifier: AGPL-3.0-only
// Drafts per chat. A chat is a link and one of its chats (the person, or one of the contact's agents, D-UI-32); each
// keeps what its composer holds: the text, the files waiting for Send (`FilesMixin.staged`) and the To and topic
// choices (`ConversationMixin`), all under [draftKey]. Nothing carries over to another chat: a file attached in one
// chat can never go out with Send in another, and coming back finds the draft as it was. The chat list says "Draft"
// on a chat that has one. Drafts live only in the window's memory and go with a lock, like the files waiting there.
//
// A chat also keeps where the person was reading it ([ReadingPosition]): coming back finds the same place, as in any
// messenger. Left at the end: the end again, unless messages came meanwhile; then the view stays on the last message
// read, with the new ones below a "New messages" line and the jump button's count. Left elsewhere: the same message at
// the same height. The person's own message always shows the end (chat_view.dart).

import 'package:flutter/foundation.dart';

import 'files.dart';
import 'threads.dart';

/// The key of a chat's draft: its link and its chat.
String draftKey(String linkId, ThreadKey t) => '$linkId/${t.id}';

/// Where a person was reading a chat when they left it.
@immutable
final class ReadingPosition {
  const ReadingPosition({required this.atEnd, required this.newestId, required this.anchorId, required this.anchorTop});

  /// The view was at the end of the chat.
  final bool atEnd;

  /// The chat's newest message then: what came after it is new.
  final String? newestId;

  /// The message at the top of the view, and how far its top was below the top of the view (negative: cut off).
  final String? anchorId;
  final double anchorTop;
}

mixin DraftsMixin on ChangeNotifier {
  ThreadKey openThreadOf(String linkId);
  List<StagedAttachment> stagedIn(String linkId, ThreadKey t);
  void safeNotify();

  final Map<String, String> _draftText = {};

  /// The text a chat's composer held when it was last on screen.
  String draftTextOf(String linkId, ThreadKey t) => _draftText[draftKey(linkId, t)] ?? '';

  /// The composer's text of a chat, kept as it is typed; the chat list hears when a draft appears or goes.
  void setDraftText(String linkId, ThreadKey t, String text) {
    final k = draftKey(linkId, t);
    final had = (_draftText[k] ?? '').trim().isNotEmpty;
    if (text.isEmpty) {
      _draftText.remove(k);
    } else {
      _draftText[k] = text;
    }
    if (had != text.trim().isNotEmpty) safeNotify();
  }

  /// The chat has something unsent in its composer: text or files.
  bool hasDraft(String linkId, ThreadKey t) =>
      draftTextOf(linkId, t).trim().isNotEmpty || stagedIn(linkId, t).isNotEmpty;

  /// The draft in one line for the chat list: its text, or the names of its files.
  String draftLine(String linkId, ThreadKey t) {
    final text = draftTextOf(linkId, t).trim();
    if (text.isNotEmpty) return text.replaceAll('\n', ' ');
    return [for (final a in stagedIn(linkId, t)) a.name].join(', ');
  }

  final Map<String, ReadingPosition> _reading = {};

  /// Where the person left the chat [t] of [linkId], if they read it before.
  ReadingPosition? readingPositionOf(String linkId, ThreadKey t) => _reading[draftKey(linkId, t)];

  /// Kept as the person reads (nothing on screen changes, so nobody is told).
  void keepReadingPosition(String linkId, ThreadKey t, ReadingPosition p) => _reading[draftKey(linkId, t)] = p;

  void clearDrafts() {
    _draftText.clear();
    _reading.clear();
  }
}
