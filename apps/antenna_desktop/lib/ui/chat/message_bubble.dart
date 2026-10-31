// SPDX-License-Identifier: AGPL-3.0-only
// Message bubble. A contact's text is data only: no markup, links or formatting (SPEC §9, UI injection).
// States: normal, outgoing with a delivery status, and a stream's final message marked "interrupted". The live bubble
// of a stream that is still being written is in stream_bubble.dart. In a link where agents take part the conversation
// reads like a group chat (D-UI-24): consecutive bubbles of one sender form a group under its name, every sender but
// the owner has a picture, and my agents that run here carry a "this Mac" mark. The text is selectable, copied whole
// from its menu or the button beside it, and a long one is cut with "Show all" (bubble_text.dart).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/format.dart';
import '../../state/long_text.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../files/file_card.dart' show fileSizeLabel;
import '../widgets/agent_avatar.dart';
import '../widgets/agent_logo.dart';
import '../widgets/badges.dart';
import 'bubble_text.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble(
    this.e, {
    super.key,
    required this.contact,
    this.grouped = false,
    this.signed = false,
    this.endedInterrupted = false,
    this.onApproveAndSend,
    this.onRetry,
    this.onSendAsFile,
    this.peerAgents = const [],
  });

  final ChatEntry e;
  final String contact;
  final bool grouped;

  /// The agents the contact announced (the names one can address), for a message no agent there reads.
  final List<String> peerAgents;

  /// Sign the first bubble of a group with its author (a link where agents take part, D-UI-18).
  final bool signed;

  /// Final message of a stream that broke off (`final` with `end: interrupted`): marked "interrupted".
  final bool endedInterrupted;
  final VoidCallback? onApproveAndSend;
  final VoidCallback? onRetry;

  /// A text the daemon refused as too long for one message: send it into the chat as a file instead of Retry.
  final VoidCallback? onSendAsFile;

  @override
  Widget build(BuildContext context) {
    final out = e.outgoing;
    final cut = endedInterrupted;
    final failed = e.delivery == Delivery.failed;
    // My agent's message is not mine: its bubble is the agent tint, mine stays brand blue (D-UI-18).
    final byMyAgent = out && e.viaAgent != null;
    const r = Radius.circular(XRadius.bubble);
    const tail = Radius.circular(5);
    final BoxDecoration deco;
    if (out) {
      deco = BoxDecoration(
        color: failed
            ? Color.alphaBlend(XColors.danger.withValues(alpha: 0.10), XColors.bg1)
            : (byMyAgent ? XColors.agentFill : XColors.outFill),
        borderRadius: const BorderRadius.only(topLeft: r, topRight: r, bottomLeft: r, bottomRight: tail),
        border: failed
            ? Border.all(color: XColors.danger.withValues(alpha: 0.5))
            : (byMyAgent ? Border.all(color: XColors.agent.withValues(alpha: 0.22)) : null),
      );
    } else {
      final edge = cut ? XColors.warn.withValues(alpha: 0.6) : null;
      deco = BoxDecoration(
        color: XColors.bg2,
        borderRadius: const BorderRadius.only(topLeft: r, topRight: r, bottomLeft: tail, bottomRight: r),
        border: edge != null ? Border.all(color: edge) : (XColors.isDark ? Border.all(color: XColors.line) : null),
      );
    }
    // On the blue fill of an outgoing bubble, text and captions use their own colors (contrast ≥ 4.5:1).
    final onFill = out && !failed && !byMyAgent;
    final textStyle = onFill ? XText.body.copyWith(color: XColors.outText) : XText.body;
    final metaStyle = XText.meta.copyWith(fontSize: 11, color: onFill ? XColors.outMeta : XColors.textMute);
    final l = context.l;
    final agent = e.viaAgent;
    final author = agent != null ? (out ? agent : l.viaContactAgent(contact, agent)) : (out ? l.approvalsYou : contact);
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      decoration: deco,
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          child: BubbleText(
            e.text,
            id: e.id,
            style: textStyle,
            readerTitle: author,
            readerSubtitle: hhmm(e.at),
            linkStyle: XText.label.copyWith(color: onFill ? XColors.outText : XColors.accent),
          ),
        ),
        const SizedBox(height: 4),
        Row(mainAxisSize: MainAxisSize.min, children: [
          // The daemon's word that this message was urgent (CONTROL §33): sent with the flag, or honoured here.
          if (e.urgent) ...[
            Icon(Icons.bolt_rounded,
                key: Key('urgent-${e.id}'), size: 12, color: onFill ? XColors.outMeta : XColors.danger),
            Text('${context.l.bubbleUrgent} · ',
                style: metaStyle.copyWith(color: onFill ? XColors.outMeta : XColors.danger)),
          ],
          if (cut) Text('${context.l.streamInterruptedTag} · ', style: metaStyle.copyWith(color: onFill ? XColors.outMeta : XColors.warn)),
          Text(hhmm(e.at), style: metaStyle),
          if (out && e.delivery != null) ...[const SizedBox(width: 4), DeliveryMark(e.delivery!, size: 13, onFill: onFill)],
        ]),
      ]),
    );
    final groupStart = !grouped;
    // My own messages carry no picture and no name, as in any messenger: the brand-blue bubble on the right is me
    // (D-UI-24). Only an addressee that is not the thread's obvious one is said above them ("→ everyone").
    final mine = out && e.viaAgent == null;
    final column = Column(
      crossAxisAlignment: out ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // Who wrote it (v5, SPEC §5; D-UI-18, D-UI-24): my agent, the contact, "Bob / claude-backend". Agent names are
        // the contact's data or our own: plain text, no markup.
        if (signed && groupStart && (!mine || e.to == 'everyone')) AuthorLine(e, contact: contact),
        HoverCopy(text: e.text, id: e.id, outgoing: out, child: bubble),
        if (failed) _FailedLine(e, onApproveAndSend: onApproveAndSend, onRetry: onRetry, onSendAsFile: onSendAsFile),
        if (out && e.noAgent) _NoAgentLine(e, contact: contact, agents: peerAgents),
      ],
    );
    final top = EdgeInsets.only(top: grouped ? 4 : 16);
    if (!signed || mine) return Padding(padding: top, child: column);
    // A group chat of people and agents: every other sender has a picture, once per group, beside its first bubble;
    // the following bubbles keep the picture's column, so a group reads as one block.
    final Widget picture = SizedBox(
      width: avatarSize,
      child: groupStart ? ParticipantAvatar(e, contact: contact, key: Key('avatar-${e.id}')) : null,
    );
    return Padding(
      padding: top,
      child: Row(
        mainAxisAlignment: out ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!out) ...[picture, const SizedBox(width: 8)],
          Flexible(child: column),
          if (out) ...[const SizedBox(width: 8), picture],
        ],
      ),
    );
  }

  /// The pictures' size in a group chat.
  static const avatarSize = 28.0;
}

/// The picture of a message's sender in a group chat: an agent's ([AgentAvatar]) or the contact's initials. The owner
/// has none.
class ParticipantAvatar extends StatelessWidget {
  const ParticipantAvatar(this.e, {super.key, required this.contact});
  final ChatEntry e;
  final String contact;

  @override
  Widget build(BuildContext context) {
    final agent = e.viaAgent;
    if (agent != null) {
      return AgentAvatar(AgentRef(agent, mine: e.outgoing, contact: e.outgoing ? null : contact),
          size: MessageBubble.avatarSize);
    }
    return XAvatar(contact,
        size: MessageBubble.avatarSize, picture: AppScope.maybeOf(context)?.pictureOfContactLabel(contact));
  }
}

/// The author over the first bubble of a group, and the addressee when it is not the thread's obvious one ("→ everyone",
/// "→ builder"). One of my agents that runs on this computer gets the "this Mac" mark.
class AuthorLine extends StatelessWidget {
  const AuthorLine(this.e, {super.key, required this.contact});
  final ChatEntry e;
  final String contact;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final out = e.outgoing;
    final agent = e.viaAgent;
    final strong = XText.label.copyWith(fontWeight: FontWeight.w600);
    final children = <Widget>[];
    if (agent != null) {
      children.add(Text(out ? agent : l.viaContactAgent(contact, agent), style: strong.copyWith(color: XColors.agent)));
      if (out) {
        children
          ..add(const SizedBox(width: 8))
          ..add(Text(l.authorYourAgentTag, style: XText.meta.copyWith(color: XColors.textMute)));
        final m = AppScope.maybeOf(context);
        if (m != null && agentOnThisComputer(m, agent, look: AppearanceScope.maybeOf(context))) {
          children
            ..add(const SizedBox(width: 8))
            ..add(ThisComputerTag(key: Key('this-computer-${e.id}')));
        }
      }
    } else if (!out) {
      children.add(Text(contact, style: strong.copyWith(color: XColors.textDim)));
    }
    // The addressee: outgoing in the person's thread can be "everyone"; incoming may name one of my agents.
    final String? to = switch (e.to) {
      'everyone' => l.authorToEveryone,
      'agent' when !out && e.toAgent != null => e.toAgent,
      _ => null,
    };
    if (to != null) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 8));
      children.add(Text(l.authorTo(to), key: Key('author-to-${e.id}'), style: XText.meta.copyWith(color: XColors.textMute)));
    }
    return Padding(
      key: Key('author-${e.id}'),
      padding: const EdgeInsets.only(bottom: 4, left: 2, right: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// The contact's node answered that it has no agent by the name this message was addressed to (PROTOCOL §23): it
/// was delivered to the node, its owner has it, but no agent there reads it. The names one can address are the agents
/// the contact announced.
class _NoAgentLine extends StatelessWidget {
  const _NoAgentLine(this.e, {required this.contact, required this.agents});
  final ChatEntry e;
  final String contact;
  final List<String> agents;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final text = [
      l.bubbleNoAgent(e.toAgent ?? '', contact),
      agents.isEmpty ? l.bubbleNoAgentNone : l.bubbleNoAgentList(agents.join(', ')),
    ].join(' ');
    return Padding(
      key: Key('no-agent-${e.id}'),
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.person_off_outlined, size: 14, color: XColors.warn),
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(text, style: XText.meta.copyWith(color: XColors.warn))),
        ]),
      ),
    );
  }
}

class _FailedLine extends StatelessWidget {
  const _FailedLine(this.e, {this.onApproveAndSend, this.onRetry, this.onSendAsFile});
  final ChatEntry e;
  final VoidCallback? onApproveAndSend;
  final VoidCallback? onRetry;
  final VoidCallback? onSendAsFile;

  @override
  Widget build(BuildContext context) {
    final approval = e.approvalId != null;
    final l = context.l;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(approval ? Icons.gpp_maybe_outlined : Icons.error_outline, size: 14, color: approval ? XColors.warn : XColors.danger),
        const SizedBox(width: 8),
        Text(
          approval
              ? l.bubbleNeedsApproval
              : refusedAsTooLong(e)
                  ? l.bubbleTooLong(fileSizeLabel(maxMessageBytes))
                  : switch (e.error) {
                  null => l.bubbleRejectedByContact,
                  'denied' => l.bubbleDenied,
                  'rate_limited' => l.bubbleRateLimited,
                  'read_only' => l.bubbleReadOnly,
                  'rekey_required' => l.bubbleRekeyRequired,
                  'recovering' => l.bubbleRecovering,
                  'login_required' => l.bubbleLoginRequired,
                  // Any other refusal in words, with the daemon's own text, never only the code.
                  final c => e.errorMessage == null
                      ? l.bubbleNotSent(c)
                      : l.bubbleNotSentBecause(describeError(l, XControlException(c, e.errorMessage!))),
                },
          style: XText.monoSmall.copyWith(color: approval ? XColors.warn : XColors.danger),
        ),
        if (onApproveAndSend != null) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: onApproveAndSend, child: Text(l.bubbleApproveAndSend)),
        ] else if (onSendAsFile != null) ...[
          const SizedBox(width: 8),
          TextButton(key: Key('send-as-file-${e.id}'), onPressed: onSendAsFile, child: Text(l.composerSendAsFile)),
        ] else if (onRetry != null) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: onRetry, child: Text(l.bubbleRetry)),
        ],
      ]),
    );
  }
}

class DayDivider extends StatelessWidget {
  const DayDivider(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(20)),
            child: Text(label, style: XText.meta.copyWith(color: XColors.textDim, fontWeight: FontWeight.w500)),
          ),
        ),
      );
}

/// UI output in the timeline (a slash command result): not a message, never sent anywhere.
class LocalNote extends StatelessWidget {
  const LocalNote(this.e, {super.key});
  final ChatEntry e;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 640),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: XColors.bg0,
              borderRadius: BorderRadius.circular(XRadius.m),
              border: Border.all(color: XColors.line),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('›', style: XText.mono.copyWith(color: XColors.accent)),
              const SizedBox(width: 8),
              Flexible(child: Text(e.text, style: XText.mono.copyWith(fontSize: 11))),
              const SizedBox(width: 8),
              Text(hhmm(e.at), style: XText.monoSmall.copyWith(fontSize: 11)),
            ]),
          ),
        ),
      );
}

/// Receipt of an action taken on a contact's request (v2, SPEC §9): a service line, not a bubble.
class ReceiptLine extends StatelessWidget {
  const ReceiptLine(this.e, {super.key, required this.contact});
  final ChatEntry e;
  final String contact;

  @override
  Widget build(BuildContext context) {
    final r = e.receipt;
    final l = context.l;
    final who = r == null
        ? (e.receiptOutgoing ? l.receiptYourNode : contact)
        : (r.actor == 'owner' ? (e.receiptOutgoing ? l.receiptYou : contact) : r.actor);
    final what = r == null ? e.text : '${receiptActionLabel(l, r.action)}: ${receiptDecisionLabel(l, r.decision)}';
    final color = switch (r?.decision) {
      'allowed' || 'approved' || 'withdrawn' => XColors.textDim,
      'denied' || 'rate_limited' => XColors.danger,
      _ => XColors.warn,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Tooltip(
          message: '${e.receiptOutgoing ? l.receiptTooltipMine : l.receiptTooltipContact}'
              '${r == null || r.reason.isEmpty ? '' : '\n${r.reason}'}',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.receipt_long_outlined, size: 13, color: color),
            const SizedBox(width: 8),
            Text('$who · $what', style: XText.monoSmall.copyWith(color: color)),
            const SizedBox(width: 8),
            Text(hhmm(e.at), style: XText.monoSmall.copyWith(fontSize: 11)),
          ]),
        ),
      ),
    );
  }
}

/// The receipt's action in plain words.
String receiptActionLabel(AppLocalizations l, String a) => switch (a) {
      'read_inbox' || 'inbox' || 'read_messages' => l.receiptReadMessages,
      'send_message' || 'send' => l.receiptSentMessage,
      'history' => l.receiptReadHistory,
      'share_file' => l.receiptSentFile,
      'request_file' => l.receiptRequestedFile,
      'withdraw_file' => l.receiptWithdrewFile,
      'check:read' => l.receiptCheckRead,
      'check:write' => l.receiptCheckWrite,
      'check:exec' => l.receiptCheckExec,
      'deliver' => l.receiptDeliver,
      _ => a,
    };

/// The decision in plain words.
String receiptDecisionLabel(AppLocalizations l, String d) => switch (d) {
      'allowed' => l.receiptAllowed,
      'approved' => l.receiptApproved,
      'approval_required' => l.receiptApprovalRequired,
      'denied' => l.receiptDenied,
      'rate_limited' => l.receiptRateLimited,
      'withdrawn' => l.receiptWithdrawn,
      'no_such_agent' => l.receiptNoSuchAgent,
      _ => d,
    };
