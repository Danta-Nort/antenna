// SPDX-License-Identifier: AGPL-3.0-only
// A local agent's conversation (x-control/7, CONTROL §24; docs/LOCAL-ASSISTANT.md §7.2): the owner and one agent that
// the daemon runs on a model of this computer. The messages come from `local_history`; the owner's text goes with
// `local_say`, and the reply streams into the live bubble of streaming messages from `local_delta` until the turn
// ends and the history is read again. The model's text is data: plain text with control characters removed, no
// links, no images, nothing fetched. Stop ends the turn (`local_session interrupt`); New conversation deletes this one
// (`reset`). The standing line under the input says what is always true (§6.3 R1).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/local_models.dart';
import '../../state/messages.dart';
import '../../state/streams.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/local_badge.dart';
import '../widgets/x_buttons.dart';
import 'bubble_text.dart';
import 'message_bubble.dart' show DayDivider, MessageBubble;
import 'stream_bubble.dart';

class LocalChatView extends StatelessWidget {
  const LocalChatView(this.agent, {super.key});
  final String agent;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final a = m.localAgent(agent);
    if (a == null) {
      return ColoredBox(
        color: XColors.bg1,
        child: Center(child: Text(context.l.localAgentGone, style: XText.bodyDim)),
      );
    }
    final rt = m.localRuntime;
    return ColoredBox(
      key: Key('local-chat-view-$agent'),
      color: XColors.bg1,
      child: Column(children: [
        LocalChatHeader(a),
        const Divider(height: 1),
        if (a.state == LocalAgentState.noModel)
          _Banner(context.l.localNoModelBanner, key: const Key('local-no-model'))
        else if (rt != null && !rt.available)
          _Banner(context.l.localRuntimeUnavailable, key: const Key('local-chat-no-runtime')),
        Expanded(child: _LocalMessages(a, key: ValueKey('local-messages-$agent'))),
        _LocalComposer(a, key: ValueKey('local-composer-$agent')),
      ]),
    );
  }
}

/// The agent's picture, name, Local badge, model and state, and New conversation.
class LocalChatHeader extends StatelessWidget {
  const LocalChatHeader(this.a, {super.key});
  final LocalAgentInfo a;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final live = m.localChats[a.name]?.live != null;
    final model = m.localModel(a.model)?.name ?? a.model;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
      child: Row(children: [
        XAvatar(a.name, size: 40, agent: true, picture: m.pictureOfMine(agent: a.name)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(a.name, overflow: TextOverflow.ellipsis, style: XText.h2)),
              const SizedBox(width: 8),
              LocalBadge(a),
            ]),
            const SizedBox(height: 4),
            Tooltip(
              message: a.detail,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: localAgentStateColor(a.state), shape: BoxShape.circle),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text('$model · ${localAgentStateLabel(l, a.state)}',
                      key: const Key('local-chat-state'), style: XText.meta.copyWith(color: XColors.textDim)),
                ),
              ]),
            ),
          ]),
        ),
        IconButton(
          key: const Key('local-reset'),
          tooltip: l.localNewConversation,
          onPressed: live ? null : () => _confirmReset(context, a),
          icon: const Icon(Icons.restart_alt_rounded, size: 20),
        ),
      ]),
    );
  }
}

Future<void> _confirmReset(BuildContext context, LocalAgentInfo a) async {
  final l = context.l;
  final ok = await showXDialog<bool>(
    context,
    (ctx) => XDialogShell(
      title: l.localResetTitle,
      icon: Icons.restart_alt_rounded,
      width: 480,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('local-reset-confirm'),
          style: XButtons.destructiveFilled(),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l.localNewConversation),
        ),
      ],
      child: Text(l.localResetBody(a.name), style: XText.body),
    ),
  );
  if (ok != true || !context.mounted) return;
  final err = await AppScope.read(context).resetLocal(a.name);
  if (err != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(l, err))));
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: xGlow(radius: XRadius.l, color: XColors.warn, strength: 0.6),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 16, color: XColors.warn),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: XText.bodyDim.copyWith(color: XColors.text))),
        ]),
      );
}

class _LocalMessages extends StatefulWidget {
  const _LocalMessages(this.a, {super.key});
  final LocalAgentInfo a;

  @override
  State<_LocalMessages> createState() => _LocalMessagesState();
}

class _LocalMessagesState extends State<_LocalMessages> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // The timeline is reversed, so the "top" is maxScrollExtent; load the older page ahead of time.
    _scroll.addListener(() {
      final p = _scroll.position;
      if (p.pixels > p.maxScrollExtent - 240) {
        final m = AppScope.read(context);
        final c = m.localChats[widget.a.name];
        if (c != null && c.more && !c.loadingOlder) m.loadLocalHistory(widget.a.name, older: true);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final a = widget.a;
    final c = m.localChats[a.name];
    final now = m.now();
    final rows = <Widget>[];
    if (c == null || !c.loaded) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Center(child: Text(l.chatLoadingHistory, style: XText.monoSmall)),
      ));
    } else if (c.more) {
      rows.add(Center(
        child: TextButton.icon(
          onPressed: c.loadingOlder ? null : () => m.loadLocalHistory(a.name, older: true),
          icon: const Icon(Icons.expand_less, size: 16),
          label: Text(c.loadingOlder ? l.commonLoading : l.chatEarlier),
        ),
      ));
    } else if (c.items.isEmpty && c.pending == null) {
      rows.add(_Intro(a));
    }
    DateTime? day;
    LocalItem? prev;
    for (final it in c?.items ?? const <LocalItem>[]) {
      final at = DateTime.fromMillisecondsSinceEpoch(it.tsMs);
      final d = DateTime(at.year, at.month, at.day);
      if (day != d) {
        day = d;
        rows.add(DayDivider(dayLabel(l, at, now)));
        prev = null;
      }
      final grouped = prev != null &&
          prev.role == it.role &&
          prev.outcome != 'failed' &&
          at.difference(DateTime.fromMillisecondsSinceEpoch(prev.tsMs)).inMinutes < 3;
      rows.add(LocalBubble(it, agent: a, grouped: grouped, failure: c!.failures[it.turn]));
      prev = it;
    }
    final pending = c?.pending;
    if (pending != null) {
      rows.add(LocalBubble(
        LocalItem(seq: -1, turn: 0, role: 'owner', text: pending, tsMs: (c!.pendingAt ?? now).millisecondsSinceEpoch),
        agent: a,
        grouped: prev?.byOwner ?? false,
      ));
    }
    final live = c?.live;
    if (live != null) rows.add(_LiveReply(a, live));
    final err = c?.error;
    if (err != null && live == null) {
      rows.add(Padding(
        key: const Key('local-say-error'),
        padding: const EdgeInsets.only(top: 12),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.error_outline, size: 14, color: XColors.danger),
          const SizedBox(width: 8),
          Flexible(child: Text(describeError(l, err), style: XText.bodyDim.copyWith(color: XColors.danger))),
        ]),
      ));
    }
    return ListView(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
      children: rows.reversed.toList(),
    );
  }
}

/// An empty conversation: who this is, in one line.
class _Intro extends StatelessWidget {
  const _Intro(this.a);
  final LocalAgentInfo a;

  @override
  Widget build(BuildContext context) => Padding(
        key: const Key('local-intro'),
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(children: [
            XAvatar(a.name, size: 56, agent: true, picture: AppScope.maybeOf(context)?.pictureOfMine(agent: a.name)),
            const SizedBox(height: 12),
            Text(a.name, style: XText.title),
            const SizedBox(height: 4),
            Text(context.l.localIntro, textAlign: TextAlign.center, style: XText.bodyDim),
          ]),
        ),
      );
}

/// The agent's name with its Local badge, over the first bubble of its group and over the live reply.
class LocalAuthor extends StatelessWidget {
  const LocalAuthor(this.a, {super.key});
  final LocalAgentInfo a;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(a.name, style: XText.label.copyWith(fontWeight: FontWeight.w600, color: XColors.agent)),
        const SizedBox(width: 8),
        LocalBadge(a),
      ]);
}

/// One message of the conversation: the owner's on the right in brand blue, the agent's on the left with its picture
/// and, first in its group, its name and Local badge.
class LocalBubble extends StatelessWidget {
  const LocalBubble(this.item, {super.key, required this.agent, this.grouped = false, this.failure});
  final LocalItem item;
  final LocalAgentInfo agent;
  final bool grouped;

  /// Why the turn failed, when this window saw the turn end (`local_turn.detail`); otherwise the history's own.
  final String? failure;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final out = item.byOwner;
    final text = plainModelText(item.text);
    final cut = item.outcome == 'interrupted';
    final failed = item.outcome == 'failed';
    final why = (failure ?? '').isNotEmpty ? failure! : item.detail;
    final at = DateTime.fromMillisecondsSinceEpoch(item.tsMs);
    const r = Radius.circular(XRadius.bubble);
    const tail = Radius.circular(5);
    final deco = out
        ? BoxDecoration(
            color: XColors.outFill,
            borderRadius: const BorderRadius.only(topLeft: r, topRight: r, bottomLeft: r, bottomRight: tail),
          )
        : BoxDecoration(
            color: XColors.bg2,
            borderRadius: const BorderRadius.only(topLeft: r, topRight: r, bottomLeft: tail, bottomRight: r),
            border: cut
                ? Border.all(color: XColors.warn.withValues(alpha: 0.6))
                : (XColors.isDark ? Border.all(color: XColors.line) : null),
          );
    final textStyle = out ? XText.body.copyWith(color: XColors.outText) : XText.body;
    final metaStyle = XText.meta.copyWith(fontSize: 11, color: out ? XColors.outMeta : XColors.textMute);
    final children = <Widget>[];
    if (text.isNotEmpty || !failed) {
      children.add(Container(
        key: Key('local-bubble-${item.seq}'),
        constraints: const BoxConstraints(maxWidth: 560),
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        decoration: deco,
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: BubbleText(
              text,
              id: 'local-${item.seq}',
              style: textStyle,
              readerTitle: out ? l.approvalsYou : agent.name,
              readerSubtitle: hhmm(at),
              linkStyle: XText.label.copyWith(color: out ? XColors.outText : XColors.accent),
            ),
          ),
          const SizedBox(height: 4),
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (cut)
              Tooltip(
                message: why,
                child: Text('${l.streamInterruptedTag} · ', style: metaStyle.copyWith(color: XColors.warn)),
              ),
            Text(hhmm(at), style: metaStyle),
          ]),
        ]),
      ));
    }
    if (failed) {
      children.add(Padding(
        key: Key('local-failed-turn-${item.turn}'),
        padding: EdgeInsets.only(top: children.isEmpty ? 0 : 8),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.error_outline, size: 14, color: XColors.danger)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              why.isEmpty ? l.localTurnFailed : l.localTurnFailedDetail(why),
              style: XText.bodyDim.copyWith(color: XColors.danger),
            ),
          ),
        ]),
      ));
    }
    final top = EdgeInsets.only(top: grouped ? 4 : 16);
    if (out) {
      return Padding(
        padding: top,
        child: Align(
          alignment: Alignment.centerRight,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: children),
        ),
      );
    }
    return Padding(
      padding: top,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: MessageBubble.avatarSize,
          child: grouped
              ? null
              : XAvatar(agent.name,
                  size: MessageBubble.avatarSize,
                  agent: true,
                  picture: AppScope.maybeOf(context)?.pictureOfMine(agent: agent.name)),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!grouped)
              Padding(
                key: Key('local-author-${item.seq}'),
                padding: const EdgeInsets.only(bottom: 4, left: 2, right: 2),
                child: LocalAuthor(agent),
              ),
            ...children,
          ]),
        ),
      ]),
    );
  }
}

/// The reply being written: the live bubble of streaming messages, with what the agent is busy with.
class _LiveReply extends StatelessWidget {
  const _LiveReply(this.a, this.live);
  final LocalAgentInfo a;
  final LocalLiveTurn live;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final s = LiveStream(
      streamId: 'local-${a.name}',
      linkId: '',
      contact: a.name,
      outgoing: false,
      startedAt: live.startedAt,
    )
      ..text = plainModelText(live.text)
      ..activity = live.stopping
          ? l.localStopping
          : switch (live.activity) {
              'loading' => l.localActivityLoading,
              'waiting' => l.localActivityWaiting,
              _ => null,
            };
    return Padding(
      key: const Key('local-live'),
      padding: const EdgeInsets.only(left: MessageBubble.avatarSize + 8),
      child: StreamBubble(s, contact: a.name, author: LocalAuthor(a)),
    );
  }
}

/// The input line: Enter sends, Shift+Enter is a new line; during a turn the button stops it.
class _LocalComposer extends StatefulWidget {
  const _LocalComposer(this.a, {super.key});
  final LocalAgentInfo a;

  @override
  State<_LocalComposer> createState() => _LocalComposerState();
}

class _LocalComposerState extends State<_LocalComposer> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        unawaited(_submit());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _blocked => widget.a.state == LocalAgentState.noModel;

  Future<void> _submit() async {
    final m = AppScope.read(context);
    final text = _text.text.trim();
    if (text.isEmpty || _blocked || m.localChats[widget.a.name]?.live != null) return;
    _text.clear();
    final err = await m.sayLocal(widget.a.name, text);
    // Refused before the turn began: the text comes back to the field, nothing is lost.
    if (err != null && mounted && _text.text.isEmpty) _text.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final live = m.localChats[widget.a.name]?.live;
    final Widget button = live != null
        ? IconButton(
            key: const Key('local-stop'),
            tooltip: l.localStop,
            onPressed: live.stopping ? null : () => m.interruptLocal(widget.a.name),
            style: XButtons.secondary().copyWith(
              shape: const WidgetStatePropertyAll(CircleBorder()),
              minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            icon: Icon(Icons.stop_rounded, size: 20, color: XColors.danger),
          )
        : IconButton(
            key: const Key('local-send'),
            tooltip: l.composerSend,
            onPressed: _blocked ? null : _submit,
            style: XButtons.primary().copyWith(
              shape: const WidgetStatePropertyAll(CircleBorder()),
              minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            icon: Icon(Icons.arrow_upward_rounded, size: 20, color: XColors.onAccent),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AnimatedBuilder(
          animation: _focus,
          builder: (context, child) => AnimatedContainer(
            duration: XMotion.fast,
            decoration: BoxDecoration(
              color: XColors.bg2,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: _focus.hasFocus ? XColors.accentLine : XColors.line, width: _focus.hasFocus ? 1.5 : 1),
            ),
            child: child,
          ),
          child: Row(children: [
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const Key('local-composer'),
                controller: _text,
                focusNode: _focus,
                minLines: 1,
                maxLines: 6,
                enabled: !_blocked,
                style: XText.body,
                decoration: InputDecoration(
                  hintText: l.localComposerHint(widget.a.name),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                ),
              ),
            ),
            Padding(padding: const EdgeInsets.all(4), child: button),
          ]),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.wifi_off_rounded, size: 12, color: XColors.textMute),
          const SizedBox(width: 4),
          Flexible(child: Text(l.localStandingLine, key: const Key('local-standing'), style: XText.meta)),
        ]),
      ]),
    );
  }
}
