// SPDX-License-Identifier: AGPL-3.0-only
// The composer's address line (v6, CONTROL §20, D-UI-18, D-UI-32): who the next message is for and its topic (none,
// an existing one, or a new one). A chat with one of the contact's agents writes to that agent, so it has no choice of
// recipient; the person chat offers the person (the default) or everyone on the contact's computer once there is
// someone else there. The topic defaults to the open chat's topic filter. The line appears when there is something to
// say; otherwise the "#" button in the input line is all there is, and a conversation between two people keeps its
// quiet look. The daemon, not the window, decides what each agent of the
// contact can read; when the contact's node is older and cannot address, the line says so instead of pretending.
// Addressing and topics are experimental in this preview (D-94): the line ends with the Experimental tag, and the
// topic menu says so in its first line.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/threads.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/agent_logo.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';

class AddressLine extends StatelessWidget {
  const AddressLine(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    if (!m.addressing) return const SizedBox.shrink();
    final l = context.l;
    final everyone = m.everyoneOffered(c.linkId);
    final agentChat = !m.openThreadOf(c.linkId).isPerson;
    final to = m.recipientOf(c.linkId);
    final topic = m.topicChoiceOf(c.linkId);
    // An older node cannot address: its every agent reads the message, and the line says so where it matters
    final oldNode = (everyone || agentChat) && !c.peerAddressing;
    if (!everyone && topic.isNone && !oldNode) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (everyone || !topic.isNone)
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (everyone) _ToPicker(c, to: to),
            if (!topic.isNone) TopicPicker(c, chip: true),
            const ExperimentalTag(key: Key('experimental-address')),
          ]),
        if (oldNode)
          Padding(
            key: const Key('composer-old-node'),
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.info_outline_rounded, size: 14, color: XColors.warn),
              ),
              const SizedBox(width: 8),
              Flexible(child: Text(l.composerOldNode(c.label), style: XText.meta.copyWith(color: XColors.textDim))),
            ]),
          ),
      ]),
    );
  }
}

/// The recipient's name as the owner sees it.
String recipientLabel(AppLocalizations l, ContactInfo c, Recipient r) => switch (r.kind) {
      RecipientKind.person => c.label,
      RecipientKind.everyone => l.composerToEveryoneOn(c.label),
      RecipientKind.agent => l.viaContactAgent(c.label, r.agent!),
    };

class _ToPicker extends StatelessWidget {
  const _ToPicker(this.c, {required this.to});
  final ContactInfo c;
  final Recipient to;

  Widget _icon(Recipient r, {Color? color}) => switch (r.kind) {
        RecipientKind.person => Icon(Icons.person_outline_rounded, size: 15, color: color ?? XColors.textDim),
        RecipientKind.everyone => Icon(Icons.groups_outlined, size: 16, color: color ?? XColors.textDim),
        RecipientKind.agent => AgentMark(AgentRef(r.agent!, contact: c.label), size: 14),
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.read(context);
    const options = [Recipient.person, Recipient.everyone];
    PopupMenuItem<Recipient> item(Recipient r) => PopupMenuItem<Recipient>(
          key: Key('to-${r.id}'),
          value: r,
          child: Row(children: [
            _icon(r),
            const SizedBox(width: 8),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(recipientLabel(l, c, r),
                    overflow: TextOverflow.ellipsis,
                    style: XText.body.copyWith(fontWeight: r == to ? FontWeight.w600 : FontWeight.w400)),
                Text(
                  switch (r.kind) {
                    RecipientKind.person => l.composerToPersonHint,
                    RecipientKind.agent => l.composerToAgentHint,
                    RecipientKind.everyone => l.composerToEveryoneOnHint,
                  },
                  style: XText.meta,
                ),
              ]),
            ),
            if (r == to) ...[const SizedBox(width: 8), Icon(Icons.check_rounded, size: 16, color: XColors.accent)],
          ]),
        );
    return PopupMenuButton<Recipient>(
      key: const Key('composer-to'),
      tooltip: l.composerToTip,
      position: PopupMenuPosition.over,
      onSelected: (r) => m.setRecipient(c.linkId, r),
      itemBuilder: (_) => [for (final r in options) item(r)],
      child: _PickerChip(
        caption: l.composerTo,
        icon: _icon(to),
        value: recipientLabel(l, c, to),
      ),
    );
  }
}

/// The topic menu: No topic, the link's topics, New topic…. As the "#" button in the input line, or as the chip of the
/// address line once a topic is chosen ([chip]).
class TopicPicker extends StatelessWidget {
  const TopicPicker(this.c, {super.key, this.chip = false});
  final ContactInfo c;
  final bool chip;

  /// The "New topic…" item: a menu item with a `null` value would count as a dismissed menu.
  static const _ask = TopicChoice.create('');

  Future<void> _newTopic(BuildContext context) async {
    final m = AppScope.read(context);
    final title = await askTopicTitle(context);
    if (title != null && title.trim().isNotEmpty) m.setTopicChoice(c.linkId, TopicChoice.create(title.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    if (!m.addressing) return const SizedBox.shrink();
    final topic = m.topicChoiceOf(c.linkId);
    final options = m.topicOptions(c.linkId);
    final hash = Text('#', style: XText.label.copyWith(color: XColors.textMute, fontWeight: FontWeight.w600));
    return PopupMenuButton<TopicChoice>(
      key: Key(chip ? 'composer-topic-chip' : 'composer-topic'),
      tooltip: l.composerTopicTip,
      position: PopupMenuPosition.over,
      onSelected: (t) {
        if (t == _ask) {
          unawaited(_newTopic(context));
        } else {
          m.setTopicChoice(c.linkId, t);
        }
      },
      itemBuilder: (_) => [
        // In a conversation between two people the "#" button is the only sign of topics: the menu says they are
        // experimental (D-94) without adding a tag to every input line.
        _TopicMenuHeader(l.composerTopicTip),
        PopupMenuItem<TopicChoice>(
          key: const Key('topic-none'),
          value: TopicChoice.none,
          child: Text(l.composerTopicNone, style: XText.body.copyWith(color: XColors.textDim)),
        ),
        for (final t in options)
          PopupMenuItem<TopicChoice>(
            key: Key('topic-${t.id.isEmpty ? t.title : t.id}'),
            value: TopicChoice.existing(t),
            child: Row(children: [
              hash,
              const SizedBox(width: 8),
              Flexible(child: Text(t.title, overflow: TextOverflow.ellipsis, style: XText.body)),
            ]),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<TopicChoice>(
          key: const Key('topic-new'),
          value: _ask,
          child: Row(children: [
            Icon(Icons.add_rounded, size: 16, color: XColors.accent),
            const SizedBox(width: 8),
            Text(l.composerTopicNew, style: XText.body.copyWith(color: XColors.accent)),
          ]),
        ),
      ],
      child: chip
          ? _PickerChip(
              icon: hash,
              value: topic.title ?? l.composerTopicNone,
              muted: topic.isNone,
              tag: topic.isNew ? l.composerTopicNewTag : null,
            )
          : Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.tag_rounded, size: 20, color: topic.isNone ? XColors.textDim : XColors.accent),
            ),
    );
  }
}

/// The topic menu's first line: what the menu is for and the Experimental tag. Not an item: it cannot be chosen.
class _TopicMenuHeader extends PopupMenuEntry<TopicChoice> {
  const _TopicMenuHeader(this.text);
  final String text;

  @override
  double get height => 36;

  @override
  bool represents(TopicChoice? value) => false;

  @override
  State<_TopicMenuHeader> createState() => _TopicMenuHeaderState();
}

class _TopicMenuHeaderState extends State<_TopicMenuHeader> {
  @override
  Widget build(BuildContext context) => Padding(
        key: const Key('topic-menu-header'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(widget.text, style: XText.meta)),
          const SizedBox(width: 8),
          const ExperimentalTag(key: Key('experimental-topic-menu')),
        ]),
      );
}

/// Ask for a new topic's title (1–120 bytes in the daemon; the field stops at 120 characters, the daemon checks bytes).
Future<String?> askTopicTitle(BuildContext context) =>
    showXDialog<String>(context, (_) => const _TopicTitleDialog());

/// The dialog owns its text field's controller: the field lives until the dialog's closing animation ends.
class _TopicTitleDialog extends StatefulWidget {
  const _TopicTitleDialog();

  @override
  State<_TopicTitleDialog> createState() => _TopicTitleDialogState();
}

class _TopicTitleDialogState extends State<_TopicTitleDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => XDialogShell(
        title: context.l.composerTopicNewTitle,
        icon: Icons.tag_rounded,
        width: 440,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonCancel)),
          FilledButton(
            key: const Key('topic-start'),
            onPressed: () => Navigator.pop(context, _c.text),
            child: Text(context.l.composerTopicStart),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.l.composerTopicNewBody, style: XText.bodyDim),
          const SizedBox(height: 16),
          TextField(
            key: const Key('topic-title'),
            controller: _c,
            autofocus: true,
            maxLength: 120,
            decoration: InputDecoration(labelText: context.l.composerTopicField, counterText: ''),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ]),
      );
}

/// A small picker chip of the address line: radius 8, a 1 px border, the value with a caret.
class _PickerChip extends StatelessWidget {
  const _PickerChip({required this.icon, required this.value, this.caption, this.muted = false, this.tag});
  final Widget icon;
  final String value;
  final String? caption;
  final bool muted;
  final String? tag;

  @override
  Widget build(BuildContext context) => Container(
        height: 28,
        padding: const EdgeInsets.only(left: 8, right: 4),
        decoration: BoxDecoration(
          color: XColors.bg1,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: XColors.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (caption != null) ...[
            Text(caption!, style: XText.meta.copyWith(color: XColors.textMute)),
            const SizedBox(width: 8),
          ],
          icon,
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: XText.label.copyWith(
                color: muted ? XColors.textDim : XColors.text,
                fontWeight: muted ? FontWeight.w400 : FontWeight.w500,
              ),
            ),
          ),
          if (tag != null) ...[
            const SizedBox(width: 8),
            Text(tag!, style: XText.meta.copyWith(color: XColors.accent, fontWeight: FontWeight.w600)),
          ],
          Icon(Icons.arrow_drop_down_rounded, size: 18, color: XColors.textMute),
        ]),
      );
}
