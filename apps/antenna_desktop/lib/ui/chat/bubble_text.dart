// SPDX-License-Identifier: AGPL-3.0-only
// A message's text in its bubble, and what a reader does with it: copy the whole message (the context menu, the hover
// button), select part of it, and read a long one in full.
//
// Selection. A bubble used to be a `SelectableText`, and Flutter corrects the start of a drag selection for a scroll
// of the list around it as if the list grew downwards; the chat's list is reversed (the newest at the bottom), so the
// correction has the wrong sign: when the list scrolled during a drag (the text field brings the selection's end into
// view), the start slid towards the pointer by twice the scroll and only the last lines stayed selected
// (TROUBLESHOOTING "Selecting a long message"). A `SelectionArea` keeps the start as a position in the text, not as a
// point on the screen, so a scroll during the drag cannot move it.
//
// Length. A message taller than [collapseShare] of the chat's height is shown cut, with "Show all": a reader sheet
// with one scrollable, selectable text (a list that grows downwards, where the drag correction is right) and Copy all.
// The text is the contact's data: plain text, no markup or links (SPEC §9).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';
import '../widgets/dialog_shell.dart';

/// A message taller than this share of the chat's height is shown cut, with "Show all".
const collapseShare = 0.6;

/// The chat's own height, for [collapseShare] (the window's height outside a chat).
class ChatViewHeight extends InheritedWidget {
  const ChatViewHeight({super.key, required this.height, required super.child});
  final double height;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatViewHeight>()?.height ?? MediaQuery.sizeOf(context).height;

  @override
  bool updateShouldNotify(ChatViewHeight old) => old.height != height;
}

/// Copy [text] whole and say so.
Future<void> copyMessageText(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final copied = context.l.bubbleCopied;
  await Clipboard.setData(ClipboardData(text: text));
  messenger?.showSnackBar(SnackBar(content: Text(copied), duration: const Duration(seconds: 2)));
}

/// How many lines of [text] fit in [maxHeight] at [width], or `null` when all of it fits. Measured once per text,
/// width and height: the chat rebuilds on every event.
int? _cutLines(String text, TextStyle style, double width, double maxHeight, TextScaler scaler) {
  // Far below any chat's height: not measured.
  if (text.length < 300 && '\n'.allMatches(text).length < 5) return null;
  final key = (text.hashCode, text.length, width.floor(), maxHeight.floor(), style.fontSize, style.height, scaler);
  if (_cuts.containsKey(key)) return _cuts[key];
  final p = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
    ..layout(maxWidth: width);
  final lines = p.height > maxHeight ? (maxHeight / p.preferredLineHeight).floor().clamp(3, 1 << 20) : null;
  p.dispose();
  if (_cuts.length > 512) _cuts.clear();
  return _cuts[key] = lines;
}

final _cuts = <Object, int?>{};

/// The text of a bubble: selectable, "Copy text" in its context menu, cut with "Show all" when it is long.
class BubbleText extends StatelessWidget {
  const BubbleText(this.text,
      {super.key, required this.style, required this.id, required this.readerTitle, this.readerSubtitle, this.linkStyle});
  final String text;
  final TextStyle style;

  /// The message's ID, for the keys of its controls.
  final String id;

  /// Who wrote it, and when, for the reader sheet.
  final String readerTitle;
  final String? readerSubtitle;

  /// The style of the "Show all" button on this bubble's fill.
  final TextStyle? linkStyle;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final maxHeight = ChatViewHeight.of(context) * collapseShare;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, c) {
      final cut = c.maxWidth.isFinite ? _cutLines(text, style, c.maxWidth, maxHeight, scaler) : null;
      final body = SelectionArea(
        key: Key('bubble-text-$id'),
        contextMenuBuilder: (menuContext, state) => AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: [
            ...state.contextMenuButtonItems,
            ContextMenuButtonItem(
              label: l.bubbleCopyText,
              onPressed: () {
                state.hideToolbar();
                copyMessageText(context, text);
              },
            ),
          ],
        ),
        child: Text(text, style: style, maxLines: cut, overflow: cut == null ? null : TextOverflow.ellipsis),
      );
      if (cut == null) return body;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        body,
        const SizedBox(height: 4),
        TextButton.icon(
          key: Key('show-all-$id'),
          onPressed: () => showMessageReader(context, text, title: readerTitle, subtitle: readerSubtitle),
          icon: Icon(Icons.unfold_more_rounded, size: 16, color: linkStyle?.color),
          label: Text(l.bubbleShowAll, style: linkStyle),
        ),
      ]);
    });
  }
}

/// The whole message in a sheet: one scrollable, selectable text and Copy all.
Future<void> showMessageReader(BuildContext context, String text, {required String title, String? subtitle}) =>
    showXDialog<void>(
      context,
      (context) => XDialogShell(
        key: const Key('message-reader'),
        title: title,
        subtitle: subtitle,
        icon: Icons.notes_rounded,
        width: 820,
        actions: [
          FilledButton.icon(
            key: const Key('message-reader-copy'),
            onPressed: () => copyMessageText(context, text),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(context.l.readerCopyAll),
          ),
        ],
        child: SelectableText(text, key: const Key('message-reader-text'), style: XText.body),
      ),
    );

/// A bubble with "Copy text" beside it while the pointer is over it: on the left of my bubbles, on the right of the
/// others', so it never covers the text.
class HoverCopy extends StatefulWidget {
  const HoverCopy({super.key, required this.text, required this.id, required this.outgoing, required this.child});
  final String text;
  final String id;
  final bool outgoing;
  final Widget child;

  @override
  State<HoverCopy> createState() => _HoverCopyState();
}

class _HoverCopyState extends State<HoverCopy> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final button = Visibility(
      visible: _hover,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: IconButton(
        key: Key('copy-text-${widget.id}'),
        tooltip: context.l.bubbleCopyText,
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        onPressed: () => copyMessageText(context, widget.text),
        icon: Icon(Icons.copy_rounded, color: XColors.textMute),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (widget.outgoing) button,
        Flexible(child: widget.child),
        if (!widget.outgoing) button,
      ]),
    );
  }
}
