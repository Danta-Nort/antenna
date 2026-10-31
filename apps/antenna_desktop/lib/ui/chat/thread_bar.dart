// SPDX-License-Identifier: AGPL-3.0-only
// The filter bar under the conversation header (v6, CONTROL §20, D-UI-18, D-UI-32, D-UI-44): inside an agent's chat,
// "With me" (the default), "Between agents" and "All" (field feedback 2026-10-06: "a person does not care what the
// AIs discuss among themselves... by default show the person ↔ agent conversation"); topics, when there are any,
// move into a secondary "Topics ▾" menu. The person chat keeps the plain "All" + topics bar of D-UI-18, shown only
// when there is something to filter by. Plain text tabs, the selected one on the soft brand fill (reference v3).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/threads.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/agent_logo.dart';

class ThreadBar extends StatelessWidget {
  const ThreadBar(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    if (!m.threadBarShown(c.linkId)) return const SizedBox.shrink();
    final l = context.l;
    final open = m.openThreadOf(c.linkId);
    final filter = m.filterOf(c.linkId);
    final entries = m.chatOf(c.linkId);
    final topics = topicsIn(entries, open);
    final chips = open.isPerson
        ? [
            _FilterChip(
              key: const Key('thread-filter-all'),
              selected: filter is AllMessages,
              label: l.threadFilterAll,
              onTap: () => m.setThreadFilter(c.linkId, ThreadFilter.all),
            ),
            for (final topic in topics)
              _FilterChip(
                key: Key('thread-filter-${TopicFilter(topic).id}'),
                selected: filter == TopicFilter(topic),
                icon: Text('#', style: XText.label.copyWith(color: XColors.textMute, fontWeight: FontWeight.w600)),
                label: topic.title,
                tooltip: l.threadFilterTopicTip(topic.title),
                onTap: () => m.setThreadFilter(c.linkId, TopicFilter(topic)),
              ),
            for (final a in myAgentsIn(entries, open))
              _FilterChip(
                key: Key('thread-filter-mine-$a'),
                selected: filter == MyAgentFilter(a),
                icon: AgentMark(AgentRef(a, mine: true), size: 13),
                label: a,
                tooltip: l.threadFilterMineTip(a),
                onTap: () => m.setThreadFilter(c.linkId, MyAgentFilter(a)),
              ),
          ]
        : [
            _FilterChip(
              key: const Key('thread-filter-with-me'),
              selected: filter is WithMeFilter,
              label: l.threadFilterWithMe,
              tooltip: l.threadFilterWithMeTip,
              onTap: () => m.setThreadFilter(c.linkId, const WithMeFilter()),
            ),
            _FilterChip(
              key: const Key('thread-filter-between-agents'),
              selected: filter is BetweenAgentsFilter,
              label: l.threadFilterBetweenAgents,
              tooltip: l.threadFilterBetweenAgentsTip,
              onTap: () => m.setThreadFilter(c.linkId, const BetweenAgentsFilter()),
            ),
            _FilterChip(
              key: const Key('thread-filter-all'),
              selected: filter is AllMessages,
              label: l.threadFilterAll,
              onTap: () => m.setThreadFilter(c.linkId, ThreadFilter.all),
            ),
            if (topics.isNotEmpty) _TopicsMenu(c.linkId, topics, selected: filter is TopicFilter ? filter : null),
          ];
    return Semantics(
      container: true,
      label: l.threadsLabel,
      child: Container(
        key: const Key('thread-bar'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          _Row(chips),
        ]),
      ),
    );
  }
}

/// The topic chips of an agent's chat, folded into one menu (D-UI-44): a secondary place, still available.
class _TopicsMenu extends StatelessWidget {
  const _TopicsMenu(this.linkId, this.topics, {required this.selected});
  final String linkId;
  final List<TopicRef> topics;
  final TopicFilter? selected;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    return PopupMenuButton<TopicRef>(
      key: const Key('thread-filter-topics-menu'),
      tooltip: l.threadsTopicsMenu,
      offset: const Offset(0, 28),
      itemBuilder: (ctx) => [
        for (final topic in topics)
          PopupMenuItem(
            key: Key('thread-filter-${TopicFilter(topic).id}'),
            value: topic,
            child: Row(children: [
              SizedBox(
                width: 20,
                child: selected != null && sameTopic(selected!.topic, topic)
                    ? Icon(Icons.check_rounded, size: 14, color: XColors.accent)
                    : null,
              ),
              Flexible(child: Text(topic.title, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
      onSelected: (topic) => m.setThreadFilter(linkId, TopicFilter(topic)),
      child: AnimatedContainer(
        duration: XMotion.fast,
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected != null ? XColors.accentSoft : null,
          borderRadius: _radius,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('#', style: XText.label.copyWith(color: XColors.textMute, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          Text(
            selected != null ? selected!.topic.title : l.threadsTopicsMenu,
            style: XText.meta.copyWith(
              fontSize: 12,
              color: selected != null ? XColors.accent : XColors.textDim,
              fontWeight: selected != null ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          Icon(Icons.arrow_drop_down, size: 16, color: XColors.textMute),
        ]),
      ),
    );
  }
}

/// A row of chips that scrolls sideways when it does not fit.
class _Row extends StatelessWidget {
  const _Row(this.children);
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (i, w) in children.indexed) ...[if (i > 0) const SizedBox(width: 8), w],
        ]),
      );
}

const _radius = BorderRadius.all(Radius.circular(8));

class _FilterChip extends StatelessWidget {
  const _FilterChip({super.key, required this.selected, required this.label, required this.onTap, this.icon, this.tooltip});
  final bool selected;
  final String label;
  final VoidCallback onTap;
  final Widget? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: _radius,
        child: AnimatedContainer(
          duration: XMotion.fast,
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? XColors.accentSoft : null,
            borderRadius: _radius,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[icon!, const SizedBox(width: 4)],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: XText.meta.copyWith(
                  fontSize: 12,
                  color: selected ? XColors.accent : XColors.textDim,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }
}

/// Nothing in the open thread (or under its filter) yet.
class ThreadEmpty extends StatelessWidget {
  const ThreadEmpty({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        key: const Key('thread-empty'),
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(child: Text(context.l.threadEmpty, style: XText.bodyDim)),
      );
}
