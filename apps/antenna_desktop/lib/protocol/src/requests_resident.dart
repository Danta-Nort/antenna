// SPDX-License-Identifier: AGPL-3.0-only
// Resident agents (x-control/6, CONTROL §21, D-93): a part of requests.dart. Owner commands.

part of 'requests.dart';

/// The owner's own turn in a resident session: a dialog with `resident_delta` events and a final `resident_turn`.
/// [toContact]: the answer goes to the contact as the agent's reply instead; [interrupt]: the turn in progress stops
/// first.
final class WakeSayRequest extends XRequest {
  const WakeSayRequest({required this.contact, required this.text, this.toContact = false, this.interrupt = false});
  final String contact;
  final String text;
  final bool toContact;
  final bool interrupt;
  @override
  String get cmd => 'wake_say';
  @override
  Json get fields => {
        'contact': contact,
        'text': text,
        if (toContact) 'to_contact': true,
        if (interrupt) 'interrupt': true,
      };
}

/// What `wake_session` does.
enum ResidentAction {
  status('status'),
  stop('stop'),
  compact('compact'),

  /// Needs the owner's password: the transcript and notes go, the taint is cleared, the next turn starts afresh.
  reset('reset');

  const ResidentAction(this.wire);
  final String wire;
}

/// A resident session command; [password] only for [ResidentAction.reset].
final class WakeSessionRequest extends XRequest {
  const WakeSessionRequest({required this.contact, required this.action, this.password});
  final String contact;
  final ResidentAction action;
  final String? password;
  @override
  String get cmd => 'wake_session';
  @override
  Json get fields => {'contact': contact, 'action': action.wire, 'password': ?password};
}
