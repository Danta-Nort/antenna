// SPDX-License-Identifier: AGPL-3.0-only
// Chats per agent (x-control/7, CONTROL §26; crates/antenna-proto/src/control/chats.rs): a part of models.dart. A
// link's messages fall into chats by the counterpart on the contact's side, the person or one of the contact's
// agents; the daemon derives them from the stored messages. What the owner sets for a chat (a local name,
// notifications, archive) stays on this node and is never sent.

part of 'models.dart';

/// A chat's notifications (`ChatInfo.notify`).
abstract final class ChatNotify {
  /// Every new incoming message (the default for the person chat).
  static const all = 'all';

  /// Only what asks for the owner: messages addressed to the owner in person, and approval requests (the default for
  /// a chat with an agent).
  static const asks = 'asks';

  /// No notifications for messages (approval requests still notify).
  static const off = 'off';

  /// In `chat_set` only: back to the default of the chat's kind.
  static const byDefault = 'default';
}

/// One chat of a link (`chats`, `chat_set`, the `chat` event).
final class ChatInfo {
  const ChatInfo({
    required this.contact,
    required this.linkId,
    this.agent,
    this.name,
    this.notify = ChatNotify.all,
    this.notifySet = false,
    this.archived = false,
    this.archivedMs,
    this.count = 0,
    this.unread = 0,
    this.lastSeq,
    this.lastMs,
    this.last,
    this.saved = false,
  });

  factory ChatInfo.fromJson(Json j) => ChatInfo(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        agent: _optStr(j, 'agent'),
        name: _optStr(j, 'name'),
        notify: _optStr(j, 'notify') ?? (j['agent'] == null ? ChatNotify.all : ChatNotify.asks),
        notifySet: _bool(j, 'notify_set'),
        archived: _bool(j, 'archived'),
        archivedMs: _optInt(j, 'archived_ms'),
        count: _optInt(j, 'count') ?? 0,
        unread: _optInt(j, 'unread') ?? 0,
        lastSeq: _optInt(j, 'last_seq'),
        lastMs: _optInt(j, 'last_ms'),
        last: j['last'] is Map<String, Object?> ? HistoryItem.fromJson(_obj(j, 'last')) : null,
        saved: _bool(j, 'saved'),
      );

  /// The contact's label.
  final String contact;
  final String linkId;

  /// The contact's agent; `null` for the person chat.
  final String? agent;

  /// The owner's local name ("Payments API"); never sent.
  final String? name;

  /// `all` / `asks` / `off` ([ChatNotify]): the owner's choice, or the default of the chat's kind.
  final String notify;

  /// [notify] is the owner's choice.
  final bool notifySet;

  /// Archived and nothing written in it since.
  final bool archived;
  final int? archivedMs;

  /// Messages in the chat (text, files, file requests).
  final int count;

  /// Incoming text messages the owner has not read.
  final int unread;
  final int? lastSeq;

  /// When the latest message was received or written here (Unix ms).
  final int? lastMs;

  /// The latest message.
  final HistoryItem? last;

  /// The owner created the chat or changed one of its settings.
  final bool saved;

  bool get isPerson => agent == null;

  ChatInfo copyWith({
    String? contact,
    String? name,
    bool clearName = false,
    String? notify,
    bool? notifySet,
    bool? archived,
    int? archivedMs,
    bool clearArchivedMs = false,
    int? count,
    int? unread,
    int? lastSeq,
    int? lastMs,
    HistoryItem? last,
    bool? saved,
  }) =>
      ChatInfo(
        contact: contact ?? this.contact,
        linkId: linkId,
        agent: agent,
        name: clearName ? null : (name ?? this.name),
        notify: notify ?? this.notify,
        notifySet: notifySet ?? this.notifySet,
        archived: archived ?? this.archived,
        archivedMs: clearArchivedMs ? null : (archivedMs ?? this.archivedMs),
        count: count ?? this.count,
        unread: unread ?? this.unread,
        lastSeq: lastSeq ?? this.lastSeq,
        lastMs: lastMs ?? this.lastMs,
        last: last ?? this.last,
        saved: saved ?? this.saved,
      );

  /// The same chat in the protocol's shape (the fake daemon, tests).
  Json toJson() => {
        'contact': contact,
        'link_id': linkId,
        'agent': ?agent,
        'name': ?name,
        'notify': notify,
        if (notifySet) 'notify_set': true,
        if (archived) 'archived': true,
        'archived_ms': ?archivedMs,
        'count': count,
        'unread': unread,
        'last_seq': ?lastSeq,
        'last_ms': ?lastMs,
        if (saved) 'saved': true,
      };

  /// The local name is the owner's: kept out of logs.
  @override
  String toString() => 'ChatInfo($linkId, ${agent == null ? 'person' : 'agent'}, unread $unread)';
}

/// `chats` (v7): per link the person chat first, then the chats with the contact's agents, the most recent first.
final class ChatsReply extends Reply {
  const ChatsReply(this.chats);

  factory ChatsReply.fromJson(Json j) => ChatsReply([for (final c in _list(j, 'chats')) ChatInfo.fromJson(c)]);

  final List<ChatInfo> chats;
}

/// One chat after `chat_set` (v7).
final class ChatReply extends Reply {
  const ChatReply(this.chat);
  final ChatInfo chat;
}

/// The owner changed a chat's local settings (v7; another window, the CLI).
final class ChatEvent extends XEvent {
  const ChatEvent(this.chat);
  final ChatInfo chat;
}
