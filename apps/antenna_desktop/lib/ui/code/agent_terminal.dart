// SPDX-License-Identifier: AGPL-3.0-only
// An agent's terminal in the dock of Code mode (D-83, D-UI-16): xterm's view of the run's terminal, with copying that
// keeps blanks (terminal_text.dart) and the platform's copy and paste keys.
//
// Scrolling back. On the main screen the terminal keeps a bounded scrollback (`AgentRun.scrollbackLines`): the
// trackpad, the wheel and the scrollbar scroll it; new output keeps the view where the person reads and follows the
// end only when the view is already there (xterm's own rule), and "Jump to the latest" brings it back. A program on the
// alternate screen (Claude Code) has no scrollback in the terminal: it scrolls its own transcript when the terminal
// reports the wheel, which `terminal_mouse.dart` makes right; a program that did not ask for the wheel gets arrow keys
// there, as in other terminals.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/l10n.dart';
import '../../state/code_mode.dart';
import '../../theme/x_theme.dart';
import '../widgets/x_buttons.dart';
import 'terminal_text.dart';
import 'terminal_theme.dart';

/// Copy the selection with blanks kept (terminal_text.dart).
class _CopyIntent extends Intent {
  const _CopyIntent();
}

/// Copy and paste like a terminal on this OS: Cmd+C / Cmd+V / Cmd+A on a Mac; Ctrl+Shift+C / Ctrl+Shift+V on Linux,
/// so Ctrl+V and Ctrl+A still reach the program (xterm's defaults take them on Linux).
Map<ShortcutActivator, Intent> get _terminalShortcuts => Platform.isMacOS
    ? const {
        SingleActivator(LogicalKeyboardKey.keyC, meta: true): _CopyIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, meta: true): PasteTextIntent(SelectionChangedCause.keyboard),
        SingleActivator(LogicalKeyboardKey.keyA, meta: true): SelectAllTextIntent(SelectionChangedCause.keyboard),
      }
    : const {
        SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true): _CopyIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
            PasteTextIntent(SelectionChangedCause.keyboard),
      };

/// The terminal itself.
class AgentTerminal extends StatefulWidget {
  const AgentTerminal(this.r, {super.key});
  final AgentRun r;

  @override
  State<AgentTerminal> createState() => _AgentTerminalState();
}

class _AgentTerminalState extends State<AgentTerminal> {
  final _controller = TerminalController();
  final _scroll = ScrollController();

  /// "Jump to the latest" is on screen.
  bool _back = false;
  bool _checkQueued = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_update);
    widget.r.terminal.addListener(_update);
  }

  @override
  void didUpdateWidget(AgentTerminal old) {
    super.didUpdateWidget(old);
    if (old.r != widget.r) {
      old.r.terminal.removeListener(_update);
      widget.r.terminal.addListener(_update);
    }
  }

  @override
  void dispose() {
    widget.r.terminal.removeListener(_update);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// New output or a scroll: the button follows whether the person reads back (after the frame, when xterm has laid
  /// the new lines out and kept or moved the view).
  void _update() {
    if (_checkQueued) return;
    _checkQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkQueued = false;
      if (mounted && _readingBack != _back) setState(() => _back = _readingBack);
    });
  }

  /// The main screen is scrolled back from its end by more than half a line.
  bool get _readingBack {
    if (widget.r.terminal.isUsingAltBuffer || !_scroll.hasClients) return false;
    final p = _scroll.position;
    return p.maxScrollExtent - p.pixels > agentTerminalStyle.fontSize * 0.75;
  }

  void _jumpToLatest() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: terminalBackground,
        child: Actions(
          actions: {
            _CopyIntent: CallbackAction<_CopyIntent>(onInvoke: (_) {
              final sel = _controller.selection;
              if (sel != null) unawaited(Clipboard.setData(ClipboardData(text: terminalText(widget.r.terminal.buffer, sel))));
              return null;
            }),
          },
          child: Stack(children: [
            Positioned.fill(
              child: TerminalView(
                widget.r.terminal,
                key: Key('code-terminal-${widget.r.spec.agent}'),
                controller: _controller,
                scrollController: _scroll,
                theme: agentTerminalTheme,
                textStyle: agentTerminalStyle,
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                autofocus: true,
                keyboardAppearance: Brightness.dark,
                shortcuts: _terminalShortcuts,
              ),
            ),
            // Shown while the person reads back: new output does not move the view, this brings it to the end.
            if (_back)
              Positioned(
                right: 20,
                bottom: 16,
                child: IconButton(
                  key: Key('code-terminal-latest-${widget.r.spec.agent}'),
                  tooltip: context.l.codeJumpToLatest,
                  onPressed: _jumpToLatest,
                  style: XButtons.primary().copyWith(
                    shape: const WidgetStatePropertyAll(CircleBorder()),
                    minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
                    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                    elevation: const WidgetStatePropertyAll(2),
                  ),
                  icon: Icon(Icons.arrow_downward_rounded, size: 20, color: XColors.onAccent),
                ),
              ),
          ]),
        ),
      );
}
