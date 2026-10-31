// SPDX-License-Identifier: AGPL-3.0-only
// Chats per agent (x-control/7, CONTROL §26): a part of requests.dart. Owner commands only: an agent connection has
// none of them. Sent only to a daemon whose `hello_ok.proto` is x-control/7 or newer; a v7 daemon from before chats
// answers `unknown_command`, and the window then groups the chats itself.

part of 'requests.dart';

/// Which chat of a link: the person chat (`{}`) or the chat with one of the contact's agents.
final class ChatRef {
  const ChatRef.person() : agent = null;
  const ChatRef.agent(String this.agent);

  /// The contact's agent; `null` for the person chat.
  final String? agent;

  Json toJson() => {'agent': ?agent};

  @override
  bool operator ==(Object other) => other is ChatRef && other.agent == agent;

  @override
  int get hashCode => agent.hashCode;
}

/// The chats of every link, or of one contact.
final class ChatsRequest extends XRequest {
  const ChatsRequest({this.contact});
  final String? contact;
  @override
  String get cmd => 'chats';
  @override
  Json get fields => {'contact': ?contact};
}

/// The owner's local settings of one chat; with none given, the chat with a known agent of the contact is created.
/// [name] `""` removes the name; [notify] is `all` / `asks` / `off` / `default` ([ChatNotify]).
final class ChatSetRequest extends XRequest {
  const ChatSetRequest({required this.contact, this.agent, this.name, this.notify, this.archived});
  final String contact;
  final String? agent;
  final String? name;
  final String? notify;
  final bool? archived;
  @override
  String get cmd => 'chat_set';
  @override
  Json get fields => {
        'contact': contact,
        'agent': ?agent,
        'name': ?name,
        'notify': ?notify,
        'archived': ?archived,
      };
}
