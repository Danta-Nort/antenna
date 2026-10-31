// SPDX-License-Identifier: AGPL-3.0-only
// The conversation on screen per link (v6, CONTROL §20, D-UI-18): which chat is open (the person chat or the chat with
// one of the contact's agents, D-UI-32) and its filter, whom the composer writes to and in which topic, the link's
// topics, and marking what the owner sees read. A part of AppModel (`app_model.dart`), which holds the history and the
// contacts; the chats themselves are listed by `chat_list.dart`. In the code a chat is still a "thread" (ThreadKey):
// the same grouping by the counterpart on the contact's side.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'app_model.dart';
import 'drafts.dart';
import 'threads.dart';

mixin ConversationMixin on ChangeNotifier {
  XDaemon get daemon;

  /// The daemon speaks x-control/6: addresses, topics, per-message `unread`.
  bool get addressing;

  /// Each link's loaded history.
  Map<String, ChatThread> get chats;

  ContactInfo? contactById(String linkId);
  List<ChatEntry> chatOf(String linkId);

  /// Mark the link read up to its last incoming message (`mark_read`, v2).
  Future<void> markLinkRead(String linkId);

  /// Replace a contact in the list (a `mark_read` reply).
  void updateContact(String linkId, ContactInfo Function(ContactInfo) f);

  /// Notify the window (no error after dispose).
  void safeNotify();

  /// A call failed: the phase follows the error (locked, the daemon unreachable, the session gone).
  void daemonFailed(Object e);

  /// The daemon lists chats and reads them by chat (x-control/7, `chat_list.dart`).
  bool get chatsSupported;

  /// Mark a chat read by the daemon's `mark_read` with `chat` (`chat_list.dart`).
  Future<void> markChatRead(String linkId, ThreadKey k);

  // Per link: the open thread; per chat ([draftKey], part of its draft): the composer's choices when the owner changed
  // them. The filter is per link and chat ([_threadFilter]).
  final Map<String, ThreadKey> _openThread = {};
  final Map<String, Recipient> _toChoice = {};
  final Map<String, TopicChoice> _topicChoice = {};

  /// Per link and chat: the filter the owner chose there, remembered while the window runs (D-UI-43: switching chats
  /// and back keeps each one's own choice, unlike before).
  final Map<String, Map<ThreadKey, ThreadFilter>> _threadFilter = {};

  String _chatOf(String linkId) => draftKey(linkId, openThreadOf(linkId));

  /// The link's topics from the daemon (`topics`, v6), most recent first.
  final Map<String, List<TopicInfo>> linkTopics = {};

  /// The chat on screen for a link (the one the owner opened, or the one with the latest messages).
  ThreadKey openThreadOf(String linkId) => _openThread[linkId] ?? defaultThread(chatOf(linkId));

  /// What the open chat shows: the owner's choice for it, or its default ([defaultFilterFor]: "With me" for an
  /// agent's chat, "All" for the person chat).
  ThreadFilter filterOf(String linkId) {
    final open = openThreadOf(linkId);
    return _threadFilter[linkId]?[open] ?? defaultFilterFor(open);
  }

  /// The bar of filters is worth showing: an agent's chat always offers "With me" / "Between agents" / "All"
  /// (D-UI-44); the person chat only when it has topics or my agents to filter by, as before.
  bool threadBarShown(String linkId) {
    final open = openThreadOf(linkId);
    if (!open.isPerson) return true;
    return topicsIn(chatOf(linkId), open).isNotEmpty || myAgentsIn(chatOf(linkId), open).isNotEmpty;
  }

  /// Bubbles carry their author ("You", my agent, the contact, the contact's agent): in a link where agents take part
  /// on either side, or where a message went to everyone. A conversation between two people looks as before.
  bool authorsShown(String linkId) {
    if (contactById(linkId)?.agents.isNotEmpty ?? false) return true;
    return chatOf(linkId).any((e) => e.viaAgent != null || e.toAgent != null || e.to == 'everyone');
  }

  /// The entries of the open thread under its filter.
  List<ChatEntry> visibleChat(String linkId) {
    final open = openThreadOf(linkId);
    final f = filterOf(linkId);
    return [
      for (final e in chatOf(linkId))
        if (threadOf(e) == open && matchesFilter(e, f)) e,
    ];
  }

  /// Show another chat of a link: everything in it, the composer addressed to its counterpart; its unread messages
  /// become read.
  Future<void> openThread(String linkId, ThreadKey t) async {
    showThread(linkId, t);
    await markOpenThreadRead(linkId);
  }

  /// The chat on screen for a link becomes [t]: its own filter (its last one, or its default) comes with it; its
  /// composer is its own draft (the choices made there).
  void showThread(String linkId, ThreadKey t) {
    if (_openThread[linkId] != t) {
      _openThread[linkId] = t;
    }
    safeNotify();
  }

  /// Filter the open thread; the composer's topic follows a topic filter. Remembered for this chat (D-UI-44).
  void setThreadFilter(String linkId, ThreadFilter f) {
    _threadFilter.putIfAbsent(linkId, () => {})[openThreadOf(linkId)] = f;
    _toChoice.remove(_chatOf(linkId));
    _topicChoice.remove(_chatOf(linkId));
    safeNotify();
  }

  /// Who the composer writes to: the owner's choice in this chat, or the open thread's counterpart.
  Recipient recipientOf(String linkId) => _toChoice[_chatOf(linkId)] ?? Recipient.of(openThreadOf(linkId));

  /// Who a file sent on [linkId] now is for (PG-19), from the composer's recipient: one of the contact's agents, or
  /// everyone; the person's chat sends without an address, as before. A daemon before 0.2.0 (no `chats`) parses
  /// `share_file` strictly and gets no address.
  ({String? to, String? toAgent}) fileAddressOf(String linkId) {
    if (!chatsSupported) return (to: null, toAgent: null);
    final r = recipientOf(linkId);
    return switch (r.kind) {
      RecipientKind.agent => (to: 'agent', toAgent: r.agent),
      RecipientKind.everyone => (to: 'everyone', toAgent: null),
      RecipientKind.person => (to: null, toAgent: null),
    };
  }

  void setRecipient(String linkId, Recipient r) {
    _toChoice[_chatOf(linkId)] = r;
    safeNotify();
  }

  /// The composer's topic: the owner's choice in this chat, or the topic filter that is on.
  TopicChoice topicChoiceOf(String linkId) =>
      _topicChoice[_chatOf(linkId)] ??
      switch (filterOf(linkId)) {
        TopicFilter(:final topic) => TopicChoice.existing(topic),
        _ => TopicChoice.none,
      };

  void setTopicChoice(String linkId, TopicChoice t) {
    _topicChoice[_chatOf(linkId)] = t;
    safeNotify();
  }

  /// The person chat's To line offers the person and everyone on the contact's computer once there is someone else
  /// there: the contact announced an agent, or one wrote. A chat with an agent always writes to that agent.
  bool everyoneOffered(String linkId) {
    if (!openThreadOf(linkId).isPerson) return false;
    if (contactById(linkId)?.agents.isNotEmpty ?? false) return true;
    return chatOf(linkId).any((e) => e.kind == EntryKind.incoming && e.viaAgent != null);
  }

  /// Topics the composer offers: the daemon's list (most recent first) and any met in the loaded history.
  List<TopicRef> topicOptions(String linkId) {
    final out = <TopicRef>[for (final t in linkTopics[linkId] ?? const <TopicInfo>[]) t.ref];
    for (final e in chatOf(linkId).reversed) {
      final topic = e.topic;
      if (topic != null && topic.title.isNotEmpty && !out.any((x) => sameTopic(x, topic))) out.add(topic);
    }
    return out;
  }

  /// The link's topics (v6). A daemon without the command leaves the list as it is.
  Future<void> refreshTopics(String linkId) async {
    if (!addressing) return;
    try {
      linkTopics[linkId] = (await daemon.topics(linkId)).topics;
      safeNotify();
    } on XControlException catch (e) {
      if (e.code == XErrorCode.loginRequired || e.code == XErrorCode.locked) daemonFailed(e);
    } on XClientException catch (e) {
      daemonFailed(e);
    }
  }

  /// The open thread's unread messages become read (`mark_read` with `ids`, v6). An older daemon, or a chat where the
  /// daemon marked nothing per message, is marked up to its last incoming message, as before.
  Future<void> markOpenThreadRead(String linkId) async {
    // The daemon reads by chat (v7): exactly the open chat, however much of it is loaded
    if (chatsSupported) return markChatRead(linkId, openThreadOf(linkId));
    if (!addressing) return markLinkRead(linkId);
    final entries = chatOf(linkId);
    final ids = [for (final e in unreadIn(entries, openThreadOf(linkId))) e.id];
    if (ids.isEmpty) {
      final anyFlagged = entries.any((e) => e.kind == EntryKind.incoming && e.unread);
      if (!anyFlagged && (contactById(linkId)?.unread ?? 0) > 0) await markLinkRead(linkId);
      return;
    }
    await markIdsRead(linkId, ids);
  }

  /// Mark exactly these incoming messages read (v6).
  Future<void> markIdsRead(String linkId, List<String> ids) async {
    final t = chats[linkId];
    try {
      final c = await daemon.markRead(linkId, 0, ids: ids);
      for (final id in ids) {
        t?.byId(id)?.unread = false;
      }
      updateContact(linkId, (_) => c);
      safeNotify();
    } on XClientException catch (e) {
      daemonFailed(e);
    }
  }

  /// The window follows what the owner just sent: the thread it went to, everything in it if the filter would hide it;
  /// the chosen recipient and topic stay for the next message.
  void follow(String linkId, ChatEntry e, TopicChoice topic) {
    final to = threadOf(e);
    if (to != openThreadOf(linkId)) {
      // The choices go along to the chat the message went to (they are this draft's, which was just sent).
      final toChoice = _toChoice.remove(_chatOf(linkId));
      final topicChoice = _topicChoice.remove(_chatOf(linkId));
      _openThread[linkId] = to;
      // The new thread's own counterpart is its default anyway; "everyone" stays chosen.
      if (toChoice != null && toChoice != Recipient.of(to)) _toChoice[_chatOf(linkId)] = toChoice;
      if (topicChoice != null) _topicChoice[_chatOf(linkId)] = topicChoice;
    }
    if (!matchesFilter(e, filterOf(linkId))) _threadFilter[linkId]?.remove(to);
    if (!topic.isNone) _topicChoice[_chatOf(linkId)] = topic;
  }

  /// Forget every link's open thread, filter, composer choices and topics (another daemon, locked keys).
  void clearConversations() {
    _openThread.clear();
    _threadFilter.clear();
    _toChoice.clear();
    _topicChoice.clear();
    linkTopics.clear();
  }

  /// A link that was just selected opens the chat it had, or the one with the latest message.
  void openDefaultThread(String linkId) => _openThread[linkId] ??= defaultThread(chatOf(linkId));

  /// The chat the owner opened for a link, if any.
  ThreadKey? chosenThread(String linkId) => _openThread[linkId];

  /// A new topic now has an ID: the next messages continue it (while the owner did not choose another one).
  void keepNewTopic(String linkId, TopicChoice sent, TopicRef topic) {
    final k = _chatOf(linkId);
    if (sent.isNew && _topicChoice[k] == sent) _topicChoice[k] = TopicChoice.existing(topic);
  }
}
