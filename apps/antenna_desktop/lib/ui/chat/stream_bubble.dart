// SPDX-License-Identifier: AGPL-3.0-only
// The live bubble of a streaming message (x-control/4, CONTROL §15): text grows chunk by chunk with a cursor; a
// "what it is doing" line (only from contacts at levels 4–5 and from our own agents); a break shows "interrupted" and
// the reason; a secret in our own stream shows "waiting for your approval". Only the final message goes into history:
// when it arrives, the bubble is replaced by a normal message. The text is contact or agent data: no markup or links
// (SPEC §9).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/streams.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../approvals/approvals_view.dart';

/// The reason for a break in plain words.
String streamReasonLabel(AppLocalizations l, LiveStream s) => switch (s.reason) {
      'connection_lost' => l.streamReasonConnectionLost,
      'timeout' => l.streamReasonTimeout,
      'limit' => l.streamReasonLimit,
      'bad_frame' => l.streamReasonBadFrame,
      'sender_aborted' => l.streamReasonSenderAborted,
      'cut' => s.outgoing ? l.streamAwaitingApproval : l.streamReasonCutIncoming,
      'empty' => l.streamReasonEmpty,
      null => l.streamInterruptedTag,
      final r => r,
    };

/// `tool:Read` → "using Read…".
String streamActivityLabel(AppLocalizations l, String activity) =>
    activity.startsWith('tool:') ? l.streamActivityTool(activity.substring(5)) : activity;

class StreamBubble extends StatelessWidget {
  const StreamBubble(this.s, {super.key, required this.contact, this.agentName, this.author});
  final LiveStream s;
  final String contact;

  /// An outgoing stream from our own woken agent (the agent's name); otherwise the owner (CLI).
  final String? agentName;

  /// Drawn instead of the name line (a local agent's name with its Local badge).
  final Widget? author;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final out = s.outgoing;
    final live = s.state == LiveStreamState.streaming;
    final cut = s.state == LiveStreamState.interrupted;
    const r = Radius.circular(XRadius.bubble);
    const tail = Radius.circular(5);
    final edge = live
        ? XColors.agent.withValues(alpha: 0.55)
        : (cut ? (s.awaitingApproval ? XColors.warn : XColors.warn.withValues(alpha: 0.6)) : XColors.line);
    final fill = out ? Color.alphaBlend(XColors.accentFill.withValues(alpha: 0.08), XColors.bg1) : XColors.bg2;
    final who = out
        ? (agentName != null ? l.streamOutAgent(agentName!) : l.streamOutOwner)
        : (s.viaAgent != null ? l.viaContactAgent(contact, s.viaAgent!) : contact);
    final status = switch (s.state) {
      LiveStreamState.streaming => out ? l.streamWritingOut : l.streamWriting,
      LiveStreamState.interrupted => streamReasonLabel(l, s),
      LiveStreamState.awaitingMessage => l.streamSaving,
    };
    final statusColor = live ? XColors.agent : (cut ? XColors.warn : XColors.textMute);
    final bubble = Container(
      key: Key('stream-${s.streamId.substring(0, s.streamId.length < 8 ? s.streamId.length : 8)}'),
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.only(
          topLeft: r,
          topRight: r,
          bottomLeft: out ? r : tail,
          bottomRight: out ? tail : r,
        ),
        border: Border.all(color: edge),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (s.text.isEmpty && live)
          Text(l.streamStarting, style: XText.bodyDim.copyWith(fontStyle: FontStyle.italic))
        else if (live)
          _LiveText(s.text)
        else
          SelectableText(s.text, style: XText.body),
        const SizedBox(height: 4),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (cut) Icon(s.awaitingApproval ? Icons.gpp_maybe_outlined : Icons.content_cut_rounded, size: 13, color: statusColor),
          if (cut) const SizedBox(width: 4),
          Flexible(child: Text(status, style: XText.meta.copyWith(fontSize: 11, color: statusColor))),
        ]),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: out ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 2, right: 2),
          child: author ?? Text(who, style: XText.label.copyWith(color: XColors.agent)),
        ),
        bubble,
        if (live && s.activity != null) _Activity(streamActivityLabel(l, s.activity!)),
        if (out && !s.live && live)
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 4),
            child: Text(l.streamNotLive, style: XText.meta),
          ),
        if (s.awaitingApproval)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextButton.icon(
              key: Key('stream-approvals-${s.streamId.substring(0, s.streamId.length < 8 ? s.streamId.length : 8)}'),
              onPressed: () async {
                await AppScope.read(context).refreshApprovals();
                if (context.mounted) await showApprovalsDialog(context);
              },
              icon: const Icon(Icons.gpp_maybe_outlined, size: 16),
              label: Text(l.streamOpenApprovals),
            ),
          ),
      ]),
    );
  }
}

/// Stream text with a blinking cursor at the end.
class _LiveText extends StatefulWidget {
  const _LiveText(this.text);
  final String text;

  @override
  State<_LiveText> createState() => _LiveTextState();
}

class _LiveTextState extends State<_LiveText> with SingleTickerProviderStateMixin {
  late final _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _blink,
        builder: (context, _) => Text.rich(TextSpan(children: [
          TextSpan(text: widget.text, style: XText.body),
          // The cursor is drawn by hand: the UI font has no "▍" glyph.
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              width: 7,
              height: 16,
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1.5),
                color: XColors.agent.withValues(alpha: _blink.value < 0.55 ? 0.9 : 0.12),
              ),
            ),
          ),
        ])),
      );
}

class _Activity extends StatelessWidget {
  const _Activity(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, left: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.3, color: XColors.agent, value: 0.7),
          ),
          const SizedBox(width: 8),
          Text(text, style: XText.meta.copyWith(color: XColors.textDim)),
        ]),
      );
}
