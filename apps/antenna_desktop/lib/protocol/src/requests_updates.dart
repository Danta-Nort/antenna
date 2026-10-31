// SPDX-License-Identifier: AGPL-3.0-only
// Requests of x-control/7 (D-103, CONTROL §23 and §14): updates that install by themselves, the agent's own facts for
// the window that started it, and the name check of a received file. A part of requests.dart. A daemon older than v7
// answers each of them `unknown_command` (or `bad_request` from its strict parser): the window degrades and says so.

part of 'requests.dart';

/// "Install signed updates by itself" on this computer, on or off: the owner password both ways (the daemon checks
/// it). Reply: `update_auto`; `unsupported_install` where the installation cannot replace itself.
final class UpdateAutoSetRequest extends XRequest {
  const UpdateAutoSetRequest({required this.enabled, required this.password});
  final bool enabled;
  final String password;
  @override
  String get cmd => 'update_auto_set';
  @override
  Json get fields => {'enabled': enabled, 'password': password};
}

/// The setting and what the daemon did. Reply: `update_auto`.
final class UpdateAutoStatusRequest extends XRequest {
  const UpdateAutoStatusRequest();
  @override
  String get cmd => 'update_auto_status';
  @override
  Json get fields => const {};
}

/// Install the staged release now (the checks are the same); `not_found` when nothing is staged. With the setting off
/// the daemon keeps no keys for the restart: [password] opens them for this one install (0.1.0-preview.11, D-137),
/// `password_required` without it. Sent only when needed: a daemon before it refuses the field.
final class UpdateAutoNowRequest extends XRequest {
  const UpdateAutoNowRequest({this.password});
  final String? password;
  @override
  String get cmd => 'update_auto_now';
  @override
  Json get fields => {'password': ?password};
}

/// Postpone the staged release by an hour; `not_found` when nothing is staged.
final class UpdateAutoLaterRequest extends XRequest {
  const UpdateAutoLaterRequest();
  @override
  String get cmd => 'update_auto_later';
  @override
  Json get fields => const {};
}

/// The facts [agent] itself gets (who wrote, the level, the length; never the text), as a subscription without an
/// owner session. The daemon allows it only to a client that is a strict ancestor of the agent's bound process (the
/// window that started its terminal) and not under any agent; otherwise `forbidden`, `not_found` or `locked`.
final class AgentWatchRequest extends XRequest {
  const AgentWatchRequest(this.agent);
  final String agent;
  @override
  String get cmd => 'agent_watch';
  @override
  Json get fields => {'agent': agent};
  @override
  bool get isDialog => true;
}

/// Can received file [id] be accepted under [name] (the contact's name when absent)? Reply: `file_name`. The accept
/// checks again: another process may take the name in between.
final class FileNameCheckRequest extends XRequest {
  const FileNameCheckRequest(this.id, {this.name});
  final String id;
  final String? name;
  @override
  String get cmd => 'file_name_check';
  @override
  Json get fields => {'id': id, 'name': ?name};
}
