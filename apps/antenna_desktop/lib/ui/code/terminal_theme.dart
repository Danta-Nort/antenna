// SPDX-License-Identifier: AGPL-3.0-only
// The agent terminal's colors and font. The terminal is dark in both window themes: Claude Code and Codex draw for a
// dark terminal by default (light text, light accents), and on a white background part of their output would be
// unreadable. The frame around it (tabs, status) follows the window theme (DESIGN "Code mode").

import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart';

import '../../theme/x_theme.dart';

/// The terminal background: the dark theme's window background, so a dark window and the terminal are one surface.
const terminalBackground = Color(0xFF060D19);
const terminalForeground = Color(0xFFE3ECF8);

const agentTerminalTheme = TerminalTheme(
  cursor: Color(0xFF7AA7FF),
  selection: Color(0x6634558F),
  foreground: terminalForeground,
  background: terminalBackground,
  black: Color(0xFF1B2638),
  red: Color(0xFFFF7A87),
  green: Color(0xFF5CD6A9),
  yellow: Color(0xFFE7B867),
  blue: Color(0xFF7AA7FF),
  magenta: Color(0xFFA79BFF),
  cyan: Color(0xFF4FDDD6),
  white: Color(0xFFC9D5E6),
  brightBlack: Color(0xFF8396B6),
  brightRed: Color(0xFFFF9EA8),
  brightGreen: Color(0xFF8BE6C3),
  brightYellow: Color(0xFFF2CE8E),
  brightBlue: Color(0xFFA6C4FF),
  brightMagenta: Color(0xFFC4BCFF),
  brightCyan: Color(0xFF86ECE6),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFF975800),
  searchHitBackgroundCurrent: Color(0xFF1560F6),
  searchHitForeground: Color(0xFFFFFFFF),
);

/// The app's own monospaced font (bundled, so the terminal looks the same everywhere); missing glyphs fall back to the
/// system's monospaced fonts.
const agentTerminalStyle = TerminalStyle(
  fontFamily: XFonts.mono,
  fontSize: 12.5,
  height: 1.25,
  fontFamilyFallback: [
    'Menlo',
    'SF Mono',
    'DejaVu Sans Mono',
    'Liberation Mono',
    'Noto Sans Mono',
    'Noto Sans Symbols 2',
    'Apple Color Emoji',
    'Noto Color Emoji',
    'monospace',
  ],
);
