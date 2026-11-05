// SPDX-License-Identifier: AGPL-3.0-only
// Threads in a link's chat (v6, CONTROL §20 "Threads in a client", D-UI-18). A link is between two nodes, but the
// owner talks to different counterparts on the other side: their person and each of their agents. The window groups
// a link's messages by that counterpart: an incoming message by its author (`via_agent`, or the person), an outgoing
// one by its addressee (`to_agent` for `to: "agent"`, the person otherwise, including `everyone` and unaddressed).
// Inside a thread, topics and this side's agents are filters. This is a display rule: the daemon stores no threads.
//
// A daemon older than v6 sends no addresses: threads then follow `via_agent` only (incoming from an agent → its thread,
// everything else → the person).

import '../protocol/x_control.dart';
import 'app_model.dart';

/// The counterpart on the contact's side: their person ([agent] is `null`) or one of their agents by name.
final class ThreadKey {
  const ThreadKey._(this.agent);

  static const person = ThreadKey._(null);

  const ThreadKey.agent(String this.agent);

  /// The contact's agent (as the contact announced it); `null` is the person.
  final String? agent;

  bool get isPerson => agent == null;

  /// For widget keys: `person` or `agent-<name>`.
  String get id => agent == null ? 'person' : 'agent-$agent';

  @override
  bool operator ==(Object other) => other is ThreadKey && other.agent == agent;

  @override
  int get hashCode => agent.hashCode;

  @override
  String toString() => 'ThreadKey($id)';
}

/// What a thread shows: everything, one topic, or what one of this side's agents wrote or was sent.
sealed class ThreadFilter {
  const ThreadFilter();

  static const all = AllMessages();

  /// For widget keys.
  String get id;
}

final class AllMessages extends ThreadFilter {
  const AllMessages();

  @override
  String get id => 'all';

  @override
  bool operator ==(Object other) => other is AllMessages;

  @override
  int get hashCode => 0;
}

final class TopicFilter extends ThreadFilter {
  const TopicFilter(this.topic);
  final TopicRef topic;

  @override
  String get id => 'topic-${topic.id.isEmpty ? topic.title : topic.id}';

  @override
  bool operator ==(Object other) => other is TopicFilter && sameTopic(other.topic, topic);

  @override
  int get hashCode => topic.id.isEmpty ? topic.title.hashCode : topic.id.hashCode;
}

final class MyAgentFilter extends ThreadFilter {
  const MyAgentFilter(this.agent);

  /// This side's agent (`via_agent` of an outgoing message, `to_agent` of an incoming one).
  final String agent;

  @override
  String get id => 'mine-$agent';

  @override
  bool operator ==(Object other) => other is MyAgentFilter && other.agent == agent;

  @override
  int get hashCode => agent.hashCode;
}

/// Inside an agent's chat (D-UI-44): this side was the person, either direction — the owner's own conversation with
/// that agent, as opposed to what it exchanges with the owner's other agents. The default filter of an agent's chat
/// (field feedback 2026-10-06: a person rarely needs to read what agents discuss among themselves).
final class WithMeFilter extends ThreadFilter {
  const WithMeFilter();

  @override
  String get id => 'with-me';

  @override
  bool operator ==(Object other) => other is WithMeFilter;

  @override
  int get hashCode => 1;
}

/// Inside an agent's chat (D-UI-44): this side was one of the owner's own agents — agent-to-agent traffic.
final class BetweenAgentsFilter extends ThreadFilter {
  const BetweenAgentsFilter();

  @override
  String get id => 'between-agents';

  @override
  bool operator ==(Object other) => other is BetweenAgentsFilter;

  @override
  int get hashCode => 2;
}

/// Two topic references name the same topic: by ID when both have one (a reply from the daemon), by title otherwise
/// (the window's own message before the daemon assigned an ID).
bool sameTopic(TopicRef? a, TopicRef? b) {
  if (a == null || b == null) return a == b;
  if (a.id.isNotEmpty && b.id.isNotEmpty) return a.id == b.id;
  return a.title == b.title;
}

/// Who the composer writes to.
enum RecipientKind { person, agent, everyone }

final class Recipient {
  const Recipient._(this.kind, this.agent);

  static const person = Recipient._(RecipientKind.person, null);
  static const everyone = Recipient._(RecipientKind.everyone, null);

  const Recipient.agent(String this.agent) : kind = RecipientKind.agent;

  /// The obvious addressee of a thread: its counterpart.
  factory Recipient.of(ThreadKey t) => t.isPerson ? person : Recipient.agent(t.agent!);

  final RecipientKind kind;

  /// For [RecipientKind.agent]: the contact's agent.
  final String? agent;

  /// For widget keys: `person`, `everyone` or `agent-<name>`.
  String get id => switch (kind) {
        RecipientKind.person => 'person',
        RecipientKind.everyone => 'everyone',
        RecipientKind.agent => 'agent-$agent',
      };

  /// The thread a message to this recipient lands in (`everyone` goes to the person's thread).
  ThreadKey get thread => kind == RecipientKind.agent ? ThreadKey.agent(agent!) : ThreadKey.person;

  @override
  bool operator ==(Object other) => other is Recipient && other.kind == kind && other.agent == agent;

  @override
  int get hashCode => Object.hash(kind, agent);

  @override
  String toString() => 'Recipient($id)';
}

/// The topic of the next message: none, an existing topic, or a new one by title.
final class TopicChoice {
  const TopicChoice._(this.topic, this.newTitle);

  static const none = TopicChoice._(null, null);

  const TopicChoice.existing(TopicRef this.topic) : newTitle = null;

  const TopicChoice.create(String this.newTitle) : topic = null;

  final TopicRef? topic;
  final String? newTitle;

  bool get isNone => topic == null && newTitle == null;
  bool get isNew => newTitle != null;

  /// The title shown in the picker.
  String? get title => topic?.title ?? newTitle;

  @override
  bool operator ==(Object other) =>
      other is TopicChoice && sameTopic(other.topic, topic) && other.newTitle == newTitle;

  @override
  int get hashCode => Object.hash(topic?.id, topic?.title, newTitle);
}

/// What `send` carries for a recipient and a topic (v6).
MessageAddress addressFor(Recipient r, TopicChoice t) {
  final topicId = (t.topic?.id.isNotEmpty ?? false) ? t.topic!.id : null;
  final topic = topicId == null ? t.title : null;
  return switch (r.kind) {
    RecipientKind.person => MessageAddress.person(topic: topic, topicId: topicId),
    RecipientKind.everyone => MessageAddress.everyone(topic: topic, topicId: topicId),
    RecipientKind.agent => MessageAddress.agent(r.agent!, topic: topic, topicId: topicId),
  };
}

/// The thread a chat entry belongs to. Receipts go to the person's thread; the window's own notes stay where they were
/// written.
ThreadKey threadOf(ChatEntry e) => switch (e.kind) {
      EntryKind.incoming => e.viaAgent == null ? ThreadKey.person : ThreadKey.agent(e.viaAgent!),
      EntryKind.outgoing => e.to == 'agent' && e.toAgent != null ? ThreadKey.agent(e.toAgent!) : ThreadKey.person,
      EntryKind.local => e.noteThread ?? ThreadKey.person,
      EntryKind.receipt => ThreadKey.person,
    };

/// This side's agent in an entry: the author of an outgoing message, the addressee of an incoming one.
String? myAgentOf(ChatEntry e) => switch (e.kind) {
      EntryKind.outgoing => e.viaAgent,
      EntryKind.incoming => e.to == 'agent' ? e.toAgent : null,
      _ => null,
    };

/// The entry is shown under [f] (the window's notes always are).
bool matchesFilter(ChatEntry e, ThreadFilter f) => switch (f) {
      AllMessages() => true,
      _ when e.kind == EntryKind.local => true,
      TopicFilter(:final topic) => sameTopic(e.topic, topic),
      MyAgentFilter(:final agent) => myAgentOf(e) == agent,
      WithMeFilter() => myAgentOf(e) == null,
      BetweenAgentsFilter() => myAgentOf(e) != null,
    };

/// The filter a chat opens with (D-UI-44): an agent's chat defaults to "With me" (the person's own conversation with
/// that agent); the person chat, as before, "All".
ThreadFilter defaultFilterFor(ThreadKey k) => k.isPerson ? ThreadFilter.all : const WithMeFilter();

/// The link's threads: the person first, then the contact's agents as they announced them (active ones, and revoked
/// ones that wrote or were written to), then any other agent names met in the history.
List<ThreadKey> threadsOf(ContactInfo? c, Iterable<ChatEntry> entries) {
  final seen = <String>{};
  for (final e in entries) {
    final t = threadOf(e);
    if (!t.isPerson) seen.add(t.agent!);
  }
  final out = <ThreadKey>[ThreadKey.person];
  final listed = <String>{};
  for (final a in c?.agents ?? const <PeerAgent>[]) {
    if (!listed.add(a.name)) continue;
    if (a.state != 'revoked' || seen.contains(a.name)) out.add(ThreadKey.agent(a.name));
  }
  for (final name in seen.toList()..sort()) {
    if (!listed.contains(name)) out.add(ThreadKey.agent(name));
  }
  return out;
}

/// Topics met in a thread, the most recently active first.
List<TopicRef> topicsIn(Iterable<ChatEntry> entries, ThreadKey t) {
  final out = <TopicRef>[];
  for (final e in entries.toList().reversed) {
    final topic = e.topic;
    if (topic == null || threadOf(e) != t) continue;
    if (!out.any((x) => sameTopic(x, topic))) out.add(topic);
  }
  return out;
}

/// This side's agents that wrote or were written to in a thread, by name.
List<String> myAgentsIn(Iterable<ChatEntry> entries, ThreadKey t) {
  final out = <String>{};
  for (final e in entries) {
    final a = myAgentOf(e);
    if (a != null && threadOf(e) == t) out.add(a);
  }
  return out.toList()..sort();
}

/// Incoming messages of a thread the owner has not read (v6: `unread` on the history item).
Iterable<ChatEntry> unreadIn(Iterable<ChatEntry> entries, ThreadKey t) =>
    entries.where((e) => e.kind == EntryKind.incoming && e.unread && threadOf(e) == t);

/// The thread to open when the owner selects a link: where the latest message is (the other threads show their unread
/// counts), otherwise the person.
ThreadKey defaultThread(Iterable<ChatEntry> entries) {
  ChatEntry? last;
  for (final e in entries) {
    if (e.kind == EntryKind.local || e.kind == EntryKind.receipt) continue;
    last = e;
  }
  return last == null ? ThreadKey.person : threadOf(last);
}

/// Consecutive bubbles from one sender form a group, as in a group chat (D-UI-24): the sender's name and picture stand
/// once, over the first bubble. [e] continues [prev]'s group when both are messages (not a file card, a receipt or a
/// note) of the same kind, by the same author (the owner, one of my agents, the contact's person or one of their
/// agents), to the same addressee, on the same day and less than 3 minutes apart.
bool continuesGroup(ChatEntry? prev, ChatEntry e, {bool prevIsFile = false}) {
  if (prev == null || prevIsFile) return false;
  if (e.kind != EntryKind.incoming && e.kind != EntryKind.outgoing) return false;
  if (prev.kind != e.kind || prev.viaAgent != e.viaAgent || prev.to != e.to || prev.toAgent != e.toAgent) return false;
  final sameDay = prev.at.year == e.at.year && prev.at.month == e.at.month && prev.at.day == e.at.day;
  return sameDay && !e.at.isBefore(prev.at) && e.at.difference(prev.at).inMinutes < 3;
}
