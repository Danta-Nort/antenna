// SPDX-License-Identifier: AGPL-3.0-only
// The first-run tour on the real screens (D-151): a ring around the thing to press and one short line next to it, with
// Skip and Next on every step. It never blocks: nothing but its own card takes a click, so the owner can press the
// real button under the ring (or anything else); Escape and Skip close it. Widgets mark what the tour may point at
// with [TourTarget]; the home screen holds the [Tour] and opens the section each step is about.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_model.dart';
import '../../state/appearance.dart';
import '../../state/tour.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../widgets/x_buttons.dart';

/// What a step can point at, in the order it prefers them (the first one on screen wins).
enum TourSpot {
  /// The chat list.
  chatList,

  /// The button next to the app the AI apps step picked ([tourApp]).
  aiApp,

  /// Agents → AI apps as a whole.
  aiApps,

  /// Agents → "Connect an agent" (no AI apps card on this computer, or the Map view).
  connectAgent,

  /// Code mode's terminals.
  dock,

  /// "Invite" on the empty conversation.
  invite,

  /// "New contact" above the chat list (the conversation is folded away in a narrow window).
  newContact,
}

/// Where the marked widgets are; the coach mark measures them after each frame.
class TourAnchors extends ChangeNotifier {
  final _spots = <TourSpot, BuildContext>{};

  void _add(TourSpot spot, BuildContext context) {
    _spots[spot] = context;
    _changed();
  }

  void _remove(TourSpot spot, BuildContext context) {
    if (_spots[spot] != context) return;
    _spots.remove(spot);
    _changed();
  }

  /// Something moved (a scroll): measure again.
  void moved() => notifyListeners();

  bool _pending = false;
  bool _disposed = false;

  // Marks come and go while a frame is built (and while the home screen goes away): listeners hear about it once,
  // after the frame.
  void _changed() {
    if (_pending || _disposed) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// [spot]'s rectangle in [ancestor]'s coordinates, if it is laid out on screen.
  Rect? rectOf(TourSpot spot, RenderBox ancestor) {
    final c = _spots[spot];
    if (c == null || !c.mounted) return null;
    final box = c.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) return null;
    final r = box.localToGlobal(Offset.zero, ancestor: ancestor) & box.size;
    return r.overlaps(Offset.zero & ancestor.size) ? r : null;
  }
}

/// The tour and its marks, for everything inside the home screen.
class TourScope extends InheritedNotifier<Tour> {
  const TourScope({super.key, required Tour tour, required this.anchors, required super.child}) : super(notifier: tour);
  final TourAnchors anchors;

  Tour get tour => notifier!;

  static TourScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TourScope>();

  /// Without listening (handlers, marks).
  static TourScope? read(BuildContext context) => context.getInheritedWidgetOfExactType<TourScope>();
}

/// Marks [child] as something the tour can point at. Outside the home screen it is just [child].
class TourTarget extends StatefulWidget {
  const TourTarget(this.spot, {super.key, required this.child});
  final TourSpot spot;
  final Widget child;

  @override
  State<TourTarget> createState() => _TourTargetState();
}

class _TourTargetState extends State<TourTarget> {
  TourAnchors? _anchors;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final a = TourScope.read(context)?.anchors;
    if (a == _anchors) return;
    _anchors?._remove(widget.spot, context);
    _anchors = a?.._add(widget.spot, context);
  }

  @override
  void didUpdateWidget(TourTarget old) {
    super.didUpdateWidget(old);
    if (old.spot == widget.spot) return;
    _anchors?._remove(old.spot, context);
    _anchors?._add(widget.spot, context);
  }

  @override
  void dispose() {
    _anchors?._remove(widget.spot, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The Code mode step applies: an agent runs in the window's terminals.
bool tourAnswers(AppModel m, Appearance? look) =>
    look?.ui == InterfaceMode.code && !m.codeComing && m.liveRuns.isNotEmpty;

/// The coach mark over the whole home screen while the tour is on.
class TourOverlay extends StatefulWidget {
  const TourOverlay({super.key});

  @override
  State<TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<TourOverlay> {
  TourAnchors? _anchors;
  Rect? _rect;
  TourStep? _step;
  List<TourSpot> _spots = const [];

  /// No dialog over the home screen: Escape is the tour's, and a step may move on by itself.
  bool _front = true;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final a = TourScope.of(context)?.anchors;
    if (a != _anchors) {
      _anchors?.removeListener(_remeasure);
      _anchors = a?..addListener(_remeasure);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _anchors?.removeListener(_remeasure);
    super.dispose();
  }

  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape || !mounted || !_front) return false;
    final tour = TourScope.read(context)?.tour;
    if (tour == null || !tour.active) return false;
    tour.close();
    return true;
  }

  void _remeasure() {
    if (mounted) setState(() {});
  }

  /// After the frame: where the step's target is now, and whether the AI apps step is done (an app was connected or
  /// an agent started there, and its dialog has closed).
  void _afterFrame(Tour tour, AppModel m, bool answers) {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      Rect? r;
      for (final s in _spots) {
        r = _anchors?.rectOf(s, box);
        if (r != null) break;
      }
      if (r != _rect) setState(() => _rect = r);
    }
    if (tour.step == TourStep.aiApps && _front && (answers || m.agents.length > tour.agentsAtAiApps)) {
      tour.next(answers: answers);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = TourScope.of(context);
    final tour = scope?.tour;
    final step = tour?.step;
    if (tour == null || step == null) return const SizedBox.shrink();
    final m = AppScope.of(context);
    final l = context.l;
    _front = ModalRoute.of(context)?.isCurrent ?? true;
    final answers = tourAnswers(m, AppearanceScope.maybeOf(context));
    final steps = tourSteps(answers: answers);
    // A new step does not draw the last step's ring for a frame.
    if (step != _step) {
      _step = step;
      _rect = null;
    }
    final (spots, line) = _content(l, m, step);
    _spots = spots;
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFrame(tour, m, answers));
    final index = steps.indexOf(step);
    final last = index == steps.length - 1;
    final rect = _rect?.inflate(6);
    return Stack(children: [
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _RingPainter(rect)))),
      Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: _CardLayout(rect),
          child: _TourCard(
            key: Key('tour-${step.name}'),
            line: line,
            count: l.tourStepOf(index + 1, steps.length),
            last: last,
            onSkip: tour.close,
            onNext: () => tour.next(answers: answers),
          ),
        ),
      ),
    ]);
  }

  /// What the step points at and its line.
  (List<TourSpot>, String) _content(AppLocalizations l, AppModel m, TourStep step) {
    switch (step) {
      case TourStep.chats:
        return (const [TourSpot.chatList], l.tourChats);
      case TourStep.aiApps:
        final pick = m.aiAppsAvailable ? tourApp(m.aiAppRows, code: m.codeAvailable) : null;
        if (pick case (final row, final action)) {
          final button = switch (action) {
            TourAppAction.start => l.appsStartCode,
            TourAppAction.connect => l.appsConnect,
            TourAppAction.setUp => l.appsSetUp,
          };
          return (const [TourSpot.aiApp, TourSpot.aiApps, TourSpot.connectAgent], l.tourAppsPress(button, row.app.name));
        }
        // Nothing found to press: say how to get one, or (apps connected already, or no AI apps list here) where
        // they connect.
        final none = m.aiAppsAvailable && !m.aiAppRows.any((r) => r.found || r.connected);
        return (const [TourSpot.aiApps, TourSpot.connectAgent], none ? l.tourAppsNone : l.tourAppsHere);
      case TourStep.answers:
        return (const [TourSpot.dock], l.tourAnswers);
      case TourStep.invite:
        return (const [TourSpot.invite, TourSpot.newContact], l.tourInvite);
    }
  }
}

/// A ring around the target and a light shade over the rest, so the eye goes to the ring; it takes no clicks.
class _RingPainter extends CustomPainter {
  _RingPainter(this.rect);
  final Rect? rect;
  final bool _dark = XColors.isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null) return;
    final hole = RRect.fromRectAndRadius(r, const Radius.circular(XRadius.l));
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(hole);
    canvas.drawPath(shade, Paint()..color = XColors.scrim.withValues(alpha: XColors.isDark ? 0.42 : 0.16));
    canvas.drawRRect(
      hole.inflate(2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = XColors.accentFill.withValues(alpha: 0.22),
    );
    canvas.drawRRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = XColors.accentFill,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.rect != rect || old._dark != _dark;
}

/// The card goes below the target when it fits, else above, else beside it; with no target, at the bottom.
class _CardLayout extends SingleChildLayoutDelegate {
  _CardLayout(this.target);
  final Rect? target;

  static const _gap = 14.0;
  static const _margin = 16.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => BoxConstraints(
        maxWidth: math.max(0, math.min(340, c.maxWidth - 2 * _margin)),
        maxHeight: math.max(0, c.maxHeight - 2 * _margin),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    double x(double v) => v.clamp(_margin, math.max(_margin, size.width - child.width - _margin));
    double y(double v) => v.clamp(_margin, math.max(_margin, size.height - child.height - _margin));
    final t = target;
    if (t == null) return Offset(x((size.width - child.width) / 2), y(size.height - child.height - 32));
    final centered = t.center.dx - child.width / 2;
    if (t.bottom + _gap + child.height + _margin <= size.height) return Offset(x(centered), t.bottom + _gap);
    if (t.top - _gap - child.height >= _margin) return Offset(x(centered), t.top - _gap - child.height);
    if (t.right + _gap + child.width + _margin <= size.width) return Offset(t.right + _gap, y(t.top + 24));
    if (t.left - _gap - child.width >= _margin) return Offset(t.left - _gap - child.width, y(t.top + 24));
    return Offset(x(centered), y(t.bottom - child.height - _margin));
  }

  @override
  bool shouldRelayout(_CardLayout old) => old.target != target;
}

class _TourCard extends StatelessWidget {
  const _TourCard({super.key, required this.line, required this.count, required this.last, required this.onSkip,
      required this.onNext});
  final String line;
  final String count;
  final bool last;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.fromLTRB(XSpace.l, XSpace.m, XSpace.m, XSpace.m),
          decoration: xPanel(fill: XColors.bg1, border: XColors.accentLine, radius: XRadius.l, glow: 1.2),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(count, key: const Key('tour-count'), style: XText.meta.copyWith(color: XColors.accent)),
            const SizedBox(height: 4),
            Text(line, key: const Key('tour-line'), style: XText.title.copyWith(fontSize: XType.h3, height: 1.35)),
            const SizedBox(height: 12),
            Row(children: [
              TextButton(
                key: const Key('tour-skip'),
                style: XButtons.tertiary(),
                onPressed: onSkip,
                child: Text(l.tourSkip),
              ),
              const Spacer(),
              FilledButton(
                key: const Key('tour-next'),
                style: XButtons.primary(),
                onPressed: onNext,
                child: Text(last ? l.commonDone : l.tourNext),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
