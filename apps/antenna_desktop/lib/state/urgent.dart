// SPDX-License-Identifier: AGPL-3.0-only
// "Urgent: interrupt now" (CONTROL §33, experimental): the owner's message to one agent of an own computer interrupts
// that agent's turn instead of waiting for it to end. The composer offers it only in an agent's chat of a contact at ∞
// ("My computer"), and only as far as the daemons say they can: this one speaks x-control/7, and the contact's node
// announced `urgent/0` (`peer_urgent`). The daemon checks the same again and refuses anything else; on the receiving
// computer only the daemon's verdict (`urgent` on the history item) makes a message urgent. Pure Dart.

import '../protocol/x_control.dart';
import 'threads.dart';

/// What the composer shows for urgent in a chat.
enum UrgentOffer {
  /// Not offered: a person's chat, everyone, a contact below ∞, or a daemon older than x-control/7.
  hidden,

  /// Shown but off: the contact's Antenna is older and cannot interrupt agents.
  olderPeer,

  /// The owner may send this message as urgent.
  available,
}

/// The offer for a message to [r] on the link with [c]; [daemonProto] is this daemon's x-control version.
UrgentOffer urgentOffer(ContactInfo c, Recipient r, {required int daemonProto}) {
  if (daemonProto < 7 || c.trust != 5 || r.kind != RecipientKind.agent || r.agent == null) return UrgentOffer.hidden;
  return c.peerUrgent ? UrgentOffer.available : UrgentOffer.olderPeer;
}
