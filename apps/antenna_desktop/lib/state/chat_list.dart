// SPDX-License-Identifier: AGPL-3.0-only
// The chat list per agent (x-control/7, CONTROL §26, D-113, D-UI-32): each agent of a contact is its own chat, under
// the contact's row (the person chat: the contact in person, and messages to everyone). The daemon lists the chats
// with their unread counts, their latest message and the owner's local settings (a name, notifications, archive; kept
// on this computer, never sent); the window keeps them current from the `message` events and asks again when a count
// drifts from the contact's total. A daemon without `chats` (older than this version) gets the same rows from the
// history the window has loaded, without the settings.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'app_model.dart';
import 'threads.dart';

mixin ChatListMixin on ChangeNotifier {
  XDaemon get daemon;

  /// The `hello_ok.proto` version (`x-control/7` → 7).
  int get daemonProto;
  List<ContactInfo> get contacts;
  ContactInfo? contactById(String linkId);
  List<ChatEntry> chatOf(String linkId);

  /// Each link's loaded history.
  Map<String, ChatThread> get chats;

  /// Replace a contact in the list (a `mark_read` reply).
  void updateContact(String linkId, ContactInfo Function(ContactInfo) f);
  void safeNotify();
  void daemonFailed(Object e);

  /// The daemon lists chats (`chats` answered once since unlocking); otherwise the window groups them itself.
  bool chatsSupported = false;

  /// A v7 daemon from before chats said `unknown_command`: not asked again until the next daemon.
  bool _chatsRefused = false;

  /// The daemon's chats per link, by counterpart, kept current by events.
  final Map<String, Map<ThreadKey, ChatInfo>> chatInfo = {};

  /// Chats the owner opened in a list section that is folded away by default (Archived).
  bool archivedShown = false;

  static ThreadKey keyOf(ChatInfo c) => c.agent == null ? ThreadKey.person : ThreadKey.agent(c.agent!);

  static ChatRef refOf(ThreadKey k) => k.isPerson ? const ChatRef.person() : ChatRef.agent(k.agent!);

  /// Asks the daemon for the chats of every link, or of one. `false` when it has none to give (an older daemon).
  Future<bool> refreshChats({String? linkId}) async {
    if (daemonProto < 7 || _chatsRefused) return false;
    try {
      final list = await daemon.chats(contact: linkId);
      chatsSupported = true;
      if (linkId == null) chatInfo.clear();
      final touched = <String>{};
      for (final c in list) {
        if (touched.add(c.linkId)) chatInfo[c.linkId] = {};
        chatInfo[c.linkId]![keyOf(c)] = c;
      }
      safeNotify();
      return true;
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest) {
        _chatsRefused = true;
        chatsSupported = false;
        return false;
      }
      if (e.code == XErrorCode.loginRequired || e.code == XErrorCode.locked) daemonFailed(e);
      return false;
    } on XClientException catch (e) {
      daemonFailed(e);
      return false;
    }
  }

  /// Another daemon, locked keys: nothing is known any more.
  void clearChats() {
    chatInfo.clear();
    chatsSupported = false;
    _chatsRefused = false;
  }

  /// The owner changed a chat's settings in another window or the CLI (the `chat` event).
  void onChatEvent(ChatInfo c) {
    chatInfo.putIfAbsent(c.linkId, () => {})[keyOf(c)] = c;
  }

  /// A new message of a link: its chat's latest message and count, and its unread count unless the window read it at
  /// once ([read]). The first message of an agent nobody listed yet makes its chat.
  void noteChatMessage(String linkId, HistoryItem m, ChatEntry entry, {required bool read}) {
    if (!chatsSupported || m.isReceipt) return;
    final key = threadOf(entry);
    final chats = chatInfo.putIfAbsent(linkId, () => {});
    final c = contactById(linkId);
    final old = chats[key] ??
        ChatInfo(
          contact: c?.label ?? '',
          linkId: linkId,
          agent: key.agent,
          notify: key.isPerson ? ChatNotify.all : ChatNotify.asks,
        );
    final isNew = old.lastSeq == null || m.seq > old.lastSeq!;
    if (!isNew) return;
    final countsUnread = !m.outgoing && m.kind == 'text' && !read;
    chats[key] = old.copyWith(
      count: old.count + 1,
      unread: old.unread + (countsUnread ? 1 : 0),
      lastSeq: m.seq,
      lastMs: m.localMs,
      last: m,
      // Something new brings an archived chat back (the daemon's rule: archived while nothing newer came)
      archived: false,
    );
  }

  /// The owner read a chat: its count is zero (the daemon's `mark_read` with `chat` did it).
  void noteChatRead(String linkId, ThreadKey k, {int marked = -1}) {
    final c = chatInfo[linkId]?[k];
    if (c == null) return;
    chatInfo[linkId]![k] = c.copyWith(unread: marked < 0 ? 0 : (c.unread - marked).clamp(0, 1 << 30));
  }

  /// The chat on screen is read (`mark_read {chat, up_to_seq}`, v7): every incoming message of it up to the latest one
  /// the window knows, loaded or not, and nothing of the link's other chats.
  Future<void> markChatRead(String linkId, ThreadKey k) async {
    final info = chatInfoOf(linkId, k);
    var upTo = info?.lastSeq ?? 0;
    var flagged = false;
    for (final e in chatOf(linkId)) {
      if (e.seq == null || threadOf(e) != k) continue;
      if (e.seq! > upTo) upTo = e.seq!;
      if (e.kind == EntryKind.incoming && e.unread) flagged = true;
    }
    if ((info?.unread ?? 0) == 0 && !flagged) return;
    try {
      final c = await daemon.markRead(linkId, upTo, chat: refOf(k));
      for (final e in chats[linkId]?.entries ?? const <ChatEntry>[]) {
        if (e.seq != null && e.seq! <= upTo && threadOf(e) == k) e.unread = false;
      }
      updateContact(linkId, (_) => c);
      noteChatRead(linkId, k);
      safeNotify();
    } on XClientException catch (e) {
      daemonFailed(e);
    }
  }

  /// The daemon's counts drifted from the contacts' totals (another window, the CLI read messages): ask again.
  void reconcileChats() {
    if (!chatsSupported) return;
    for (final c in contacts) {
      final chats = chatInfo[c.linkId];
      if (chats == null) continue;
      final sum = chats.values.fold<int>(0, (a, x) => a + x.unread);
      if (sum != c.unread) unawaited(refreshChats(linkId: c.linkId));
    }
  }

  /// The daemon's chat, when it listed one.
  ChatInfo? chatInfoOf(String linkId, ThreadKey k) => chatInfo[linkId]?[k];

  /// The owner's local name of a chat.
  String? chatName(String linkId, ThreadKey k) => chatInfoOf(linkId, k)?.name;

  /// Notifications of a chat: the owner's choice or the default of its kind ([ChatNotify]).
  String chatNotify(String linkId, ThreadKey k) =>
      chatInfoOf(linkId, k)?.notify ?? (k.isPerson ? ChatNotify.all : ChatNotify.asks);

  /// Unread incoming messages of a chat: the daemon's count, or the loaded history's for an older daemon.
  int chatUnread(String linkId, ThreadKey k) {
    if (chatsSupported) return chatInfoOf(linkId, k)?.unread ?? 0;
    return unreadIn(chatOf(linkId), k).length;
  }

  /// Of [chatUnread], how many are agent-to-agent traffic (one of the owner's own agents is the addressee), counted
  /// from what is loaded (D-UI-44). A message not loaded yet (a backlog from before this window connected) counts
  /// toward "with me" instead ([chatUnreadForPerson]): the badge the owner sees for a chat they have not opened never
  /// hides something that might be for them.
  int chatUnreadBetweenAgents(String linkId, ThreadKey k) {
    final loaded = unreadIn(chatOf(linkId), k).where((e) => myAgentOf(e) != null).length;
    return loaded.clamp(0, chatUnread(linkId, k));
  }

  /// Of [chatUnread], how many are addressed to the person (or to everyone): the number the chat list's badge shows.
  int chatUnreadForPerson(String linkId, ThreadKey k) => chatUnread(linkId, k) - chatUnreadBetweenAgents(linkId, k);

  /// The chat is archived (and nothing new came since).
  bool chatArchived(String linkId, ThreadKey k) => chatInfoOf(linkId, k)?.archived ?? false;

  /// The latest message of a chat, as an entry of the loaded history (`null` when none is loaded yet).
  ChatEntry? lastEntryOf(String linkId, ThreadKey k) {
    final entries = chatOf(linkId);
    for (var i = entries.length - 1; i >= 0; i--) {
      final e = entries[i];
      if (e.kind == EntryKind.local || e.kind == EntryKind.receipt) continue;
      if (threadOf(e) == k) return e;
    }
    return null;
  }

  /// When the chat was last written in (for the order of the list).
  int chatActivityMs(String linkId, ThreadKey k) {
    final e = lastEntryOf(linkId, k);
    final fromEntry = e?.at.millisecondsSinceEpoch ?? 0;
    final fromInfo = chatInfoOf(linkId, k)?.lastMs ?? 0;
    return fromEntry > fromInfo ? fromEntry : fromInfo;
  }

  /// This mixin's companion (`chat_prefs.dart`): the stable order a link's agent chats keep (first seen, then as
  /// dragged), extended with any name not seen yet.
  List<String> chatOrderOf(String linkId, Iterable<String> present);

  /// Pinned agent names of a link, most recently pinned first (`chat_prefs.dart`).
  List<String> pinnedChatsOf(String linkId);

  /// The contact's agent chats in the list: the daemon's (or, for an older daemon, those met in the loaded history),
  /// without the archived ones, or only the archived ones with [archived]. **Not** by the latest message (field
  /// feedback 2026-10-06: a busy agent kept jumping to the top and the owner lost track of which chat was which): a
  /// stable order, pinned chats first in pin order, then the rest in the order they first appeared or were dragged
  /// to. Activity still shows as the unread badge and the time.
  List<ThreadKey> agentChatsOf(String linkId, {bool archived = false}) {
    final keys = <ThreadKey>{};
    if (chatsSupported) {
      for (final c in (chatInfo[linkId] ?? const <ThreadKey, ChatInfo>{}).values) {
        if (c.agent != null && c.archived == archived) keys.add(keyOf(c));
      }
    } else if (!archived) {
      for (final e in chatOf(linkId)) {
        final t = threadOf(e);
        if (!t.isPerson && e.kind != EntryKind.local) keys.add(t);
      }
    }
    final order = chatOrderOf(linkId, [for (final k in keys) k.agent!]);
    final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
    final pinned = pinnedChatsOf(linkId);
    return keys.toList()
      ..sort((a, b) {
        final pa = pinned.indexOf(a.agent!);
        final pb = pinned.indexOf(b.agent!);
        if (pa != pb) return (pa == -1 ? pinned.length : pa).compareTo(pb == -1 ? pinned.length : pb);
        return (rank[a.agent] ?? 1 << 30).compareTo(rank[b.agent] ?? 1 << 30);
      });
  }

  /// Every archived chat of every contact, the most recent first.
  List<(ContactInfo, ThreadKey)> archivedChats() => [
        for (final c in contacts)
          for (final k in agentChatsOf(c.linkId, archived: true)) (c, k),
      ]..sort((a, b) => chatActivityMs(b.$1.linkId, b.$2).compareTo(chatActivityMs(a.$1.linkId, a.$2)));

  /// Agents the contact announced that have no chat in the list yet: "New chat" offers them.
  List<String> newChatAgents(ContactInfo c) {
    final listed = {
      for (final k in agentChatsOf(c.linkId)) k.agent,
      for (final k in agentChatsOf(c.linkId, archived: true)) k.agent,
    };
    return [
      for (final a in c.agents)
        if (a.state != 'revoked' && !listed.contains(a.name)) a.name,
    ];
  }

  void _put(ChatInfo c) {
    chatInfo.putIfAbsent(c.linkId, () => {})[keyOf(c)] = c;
    safeNotify();
  }

  /// Apply one `chat_set`; returns the error or `null`.
  Future<Object?> _chatSet(String linkId, ThreadKey k, {String? name, String? notify, bool? archived}) async {
    try {
      _put(await daemon.chatSet(linkId, agent: k.agent, name: name, notify: notify, archived: archived));
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable || (e is XControlException && e.code == XErrorCode.loginRequired)) {
        daemonFailed(e);
      }
      return e;
    }
  }

  /// A local name for the chat (`""` removes it). Never sent.
  Future<Object?> renameChat(String linkId, ThreadKey k, String name) => _chatSet(linkId, k, name: name);

  /// Notifications of the chat: [ChatNotify.all], [ChatNotify.asks], [ChatNotify.off] or [ChatNotify.byDefault].
  Future<Object?> setChatNotify(String linkId, ThreadKey k, String notify) => _chatSet(linkId, k, notify: notify);

  /// Archive a chat with an agent, or bring it back. The person chat is the contact itself and is not archived.
  Future<Object?> archiveChat(String linkId, ThreadKey k, {required bool archived}) =>
      _chatSet(linkId, k, archived: archived);

  /// Start the chat with a known agent of the contact (it is listed before its first message).
  Future<Object?> createChat(String linkId, String agent) => _chatSet(linkId, ThreadKey.agent(agent));

  /// This mixin's companion (`chat_prefs.dart`): the chat opted into notifying about agent-to-agent traffic too.
  bool notifyAgentsOn(String linkId, String agent);

  /// Whether a new incoming message should notify by its chat's setting: `all` every message, `asks` only those
  /// addressed to the owner in person or to everyone, `off` none. Approval requests notify by themselves (D-84),
  /// whatever this says. Agent-to-agent traffic (one of the owner's own agents is the addressee) notifies only when
  /// the chat opted in (D-UI-44, off by default): a person does not usually care what the AIs discuss among
  /// themselves.
  bool chatNotifies(String linkId, ChatEntry e) {
    if (e.kind != EntryKind.incoming) return false;
    final k = threadOf(e);
    if (!k.isPerson && myAgentOf(e) != null && !notifyAgentsOn(linkId, k.agent!)) return false;
    return switch (chatNotify(linkId, k)) {
      ChatNotify.off => false,
      // In an agent's chat what got past the gate above is for the person, or the chat asked for the rest
      ChatNotify.asks => !k.isPerson || myAgentOf(e) == null,
      _ => true,
    };
  }
}
