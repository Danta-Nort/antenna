// SPDX-License-Identifier: AGPL-3.0-only
// A popover of the reference v3: a small card next to its anchor with details that do not need a page of their own
// (the "Secure" indicator, the "?" behind a setting). It opens on hover after a short wait, and on a click, a tap or
// Enter/Space for touch and keyboard; keyboard focus alone opens it too, as a tooltip would. It stays while the pointer
// is over the anchor or the card, so a link in it can be reached, and closes when the pointer leaves, on Escape, on a
// tap outside or when focus leaves. Contact data shown in a popover is plain text, as everywhere (SPEC §9).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/x_theme.dart';

class XPopover extends StatefulWidget {
  const XPopover({
    super.key,
    required this.child,
    required this.content,
    required this.label,
    this.width = 320,
    this.end = false,
    this.cardKey,
    this.radius = XRadius.m,
  });

  /// The anchor: drawn as is; the popover adds the hover, focus and click behaviour around it.
  final Widget child;

  /// The card's content; [close] closes the card (an action in it that leads elsewhere).
  final Widget Function(BuildContext context, VoidCallback close) content;

  /// What the anchor opens, for screen readers.
  final String label;

  /// The card's width.
  final double width;

  /// Align the card's right edge with the anchor's (an anchor near the right edge of the window).
  final bool end;

  /// The card's key (tests).
  final Key? cardKey;

  /// The anchor's corner radius, for the keyboard focus ring.
  final double radius;

  /// The wait before a hover opens the card, and before leaving closes it (time to move onto the card).
  static const openDelay = Duration(milliseconds: 300);
  static const closeDelay = Duration(milliseconds: 150);

  @override
  State<XPopover> createState() => _XPopoverState();
}

class _XPopoverState extends State<XPopover> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _focus = FocusNode(debugLabel: 'popover');
  Timer? _timer;
  bool _overAnchor = false;
  bool _overCard = false;

  /// The keyboard focus ring is showing.
  bool _ring = false;

  /// Opened by a click, a tap or the keyboard: stays until closed the same way, Escape or a tap outside.
  bool _pinned = false;

  /// Where the card opens: above the anchor when it sits low in the window, aligned to its right edge when the card
  /// would cross the window's right edge.
  bool _above = false;
  bool _alignEnd = false;

  @override
  void dispose() {
    _timer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _show() {
    _timer?.cancel();
    if (_portal.isShowing || !mounted) return;
    final box = context.findRenderObject();
    final screen = MediaQuery.sizeOf(context);
    if (box is RenderBox && box.hasSize) {
      final at = box.localToGlobal(Offset.zero);
      _above = at.dy + box.size.height / 2 > screen.height * 0.6;
      _alignEnd = widget.end || at.dx + widget.width > screen.width - 16;
    }
    setState(_portal.show);
  }

  void _hide() {
    _timer?.cancel();
    _pinned = false;
    if (_portal.isShowing && mounted) setState(_portal.hide);
  }

  void _hoverChanged() {
    _timer?.cancel();
    if (_overAnchor || _overCard) {
      if (!_portal.isShowing) _timer = Timer(XPopover.openDelay, _show);
    } else if (!_pinned && !_focus.hasFocus) {
      _timer = Timer(XPopover.closeDelay, _hide);
    }
  }

  void _toggle() {
    if (_portal.isShowing && _pinned) {
      _hide();
    } else {
      _pinned = true;
      _show();
    }
  }

  void _focusChanged(bool focused) {
    if (focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      _show();
    } else if (!focused && !_overAnchor && !_overCard) {
      _hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: this,
      onTapOutside: (_) => _hide(),
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _link,
          targetAnchor: switch ((_above, _alignEnd)) {
            (false, false) => Alignment.bottomLeft,
            (false, true) => Alignment.bottomRight,
            (true, false) => Alignment.topLeft,
            (true, true) => Alignment.topRight,
          },
          followerAnchor: switch ((_above, _alignEnd)) {
            (false, false) => Alignment.topLeft,
            (false, true) => Alignment.topRight,
            (true, false) => Alignment.bottomLeft,
            (true, true) => Alignment.bottomRight,
          },
          offset: Offset(0, _above ? -8 : 8),
          child: Align(
            alignment: switch ((_above, _alignEnd)) {
              (false, false) => Alignment.topLeft,
              (false, true) => Alignment.topRight,
              (true, false) => Alignment.bottomLeft,
              (true, true) => Alignment.bottomRight,
            },
            child: TapRegion(
              groupId: this,
              child: MouseRegion(
                onEnter: (_) {
                  _overCard = true;
                  _hoverChanged();
                },
                onExit: (_) {
                  _overCard = false;
                  _hoverChanged();
                },
                child: _Card(key: widget.cardKey, width: widget.width, child: widget.content(context, _hide)),
              ),
            ),
          ),
        ),
        child: CompositedTransformTarget(
          link: _link,
          child: Semantics(
            button: true,
            label: widget.label,
            expanded: _portal.isShowing,
            child: FocusableActionDetector(
              focusNode: _focus,
              onShowFocusHighlight: (on) {
                if (on != _ring) setState(() => _ring = on);
              },
              onFocusChange: _focusChanged,
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
              },
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _toggle()),
                DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => _hide()),
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) {
                  _overAnchor = true;
                  _hoverChanged();
                },
                onExit: (_) {
                  _overAnchor = false;
                  _hoverChanged();
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _focus.requestFocus();
                    _toggle();
                  },
                  // Keyboard focus: the 2 px ring of the button system, outside the anchor.
                  child: Container(
                    foregroundDecoration: _ring
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(widget.radius),
                            border: Border.all(
                                color: XColors.accentLine, width: 2, strokeAlign: BorderSide.strokeAlignOutside),
                          )
                        : null,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The card: white (the raised surface in the dark theme), radius 12, a soft shadow; it fades in over 0.2 s.
class _Card extends StatelessWidget {
  const _Card({super.key, required this.width, required this.child});
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: XMotion.normal,
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(opacity: t, child: child),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: width,
            padding: const EdgeInsets.all(16),
            decoration: xPanel(
              fill: XColors.isDark ? XColors.bg2 : XColors.bg1,
              border: XColors.isDark ? XColors.lineStrong : XColors.line,
              radius: XRadius.l,
              glow: 1.2,
            ),
            child: DefaultTextStyle(style: XText.bodyDim, child: child),
          ),
        ),
      );
}

/// The small "?" after a setting's name: the longer explanation, on hover, click or keyboard focus.
class HelpHint extends StatelessWidget {
  const HelpHint(this.text, {super.key, required this.id, required this.label, this.width = 340, this.extra});

  /// The explanation (plain text).
  final String text;

  /// Names the anchor `help-<id>` and the card `help-<id>-card` (tests).
  final String id;

  /// What it explains, for screen readers ("More about Appearance").
  final String label;
  final double width;

  /// More below the text (a second paragraph with its own style).
  final Widget? extra;

  @override
  Widget build(BuildContext context) => XPopover(
        key: Key('help-$id'),
        label: label,
        width: width,
        radius: 10,
        cardKey: Key('help-$id-card'),
        content: (_, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(text, style: XText.bodyDim.copyWith(color: XColors.text)),
          if (extra != null) ...[const SizedBox(height: 8), extra!],
        ]),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Container(
            width: 16,
            height: 16,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: XColors.lineStrong)),
            child: Text('?',
                style: XText.meta.copyWith(fontSize: 11, height: 1, color: XColors.textDim, fontWeight: FontWeight.w600)),
          ),
        ),
      );
}
