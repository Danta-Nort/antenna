// SPDX-License-Identifier: AGPL-3.0-only
// Approver agents (x-control/7, CONTROL §31, PG-57; experimental): the owner's commands that name an agent to answer
// other agents' approval requests in the owner's place, narrow or remove it, and list the approvers with the answers
// they gave. A part of requests.dart. None of them exists for an agent. Naming or widening takes the owner password
// (or an owner proof): it widens who decides; narrowing and removing take only the owner session (D-84). An older v7
// daemon refuses them (`bad_request`, "unknown variant"); the window then offers no approvers.

part of 'requests.dart';

/// Every approver command of the owner (the fake daemon routes them by this type).
sealed class ApproverRequest extends XRequest {
  const ApproverRequest();
}

/// Name [name] an approver, or replace its scope with a wider one: an agent of this computer, or with [contact] the
/// agent of that own computer (a contact at ∞) by the name it announced on the link. [agents]: whose requests it
/// answers (this computer's agents; `null`: all of them). [kinds]: which kinds ([delegableKinds]; `null`: all). The
/// owner password, never printed; `""` next to an owner proof. Reply: `approvers`.
final class ApproverSetRequest extends ApproverRequest {
  const ApproverSetRequest({required this.name, required this.password, this.contact, this.agents, this.kinds});
  final String name;
  final String? contact;
  final List<String>? agents;
  final List<String>? kinds;
  final String password;
  @override
  String get cmd => 'approver_set';
  @override
  Json get fields => {
        'name': name,
        'contact': ?contact,
        'agents': ?agents,
        'kinds': ?kinds,
        'password': password,
      };

  /// The same request with another password (`""` for a proof; the window never keeps one typed before).
  ApproverSetRequest withPassword(String password) =>
      ApproverSetRequest(name: name, contact: contact, agents: agents, kinds: kinds, password: password);
}

/// The same approver with a scope within the one it has (fewer agents, fewer kinds): no password, it only takes
/// away. A wider scope is `password_required`. Reply: `approvers`.
final class ApproverNarrowRequest extends ApproverRequest {
  const ApproverNarrowRequest({required this.name, this.contact, this.agents, this.kinds});
  final String name;
  final String? contact;
  final List<String>? agents;
  final List<String>? kinds;
  @override
  String get cmd => 'approver_narrow';
  @override
  Json get fields => {'name': name, 'contact': ?contact, 'agents': ?agents, 'kinds': ?kinds};
}

/// The approver answers nothing any more: no password. Reply: `approvers`.
final class ApproverRemoveRequest extends ApproverRequest {
  const ApproverRemoveRequest({required this.name, this.contact});
  final String name;
  final String? contact;
  @override
  String get cmd => 'approver_remove';
  @override
  Json get fields => {'name': name, 'contact': ?contact};
}

/// The approvers and their latest answers. Reply: `approvers`.
final class ApproversRequest extends ApproverRequest {
  const ApproversRequest();
  @override
  String get cmd => 'approvers';
  @override
  Json get fields => const {};
}
