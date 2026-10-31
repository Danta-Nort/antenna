// SPDX-License-Identifier: AGPL-3.0-only
// The AI apps' marks: small tiles that tell the owner at a glance which AI an app row, a Connect dialog or an agent
// is. The marks belong to their owners and are used only to identify the integration (assets/logos/README.md,
// docs/CONNECT-APPS.md "Marks"); where there is no mark we may use, a neutral monogram tile stands in.

import 'package:flutter/material.dart';

import '../../state/ai_apps.dart';
import '../../theme/ai_logos.dart';
import '../../theme/svg_path.dart';
import '../../theme/x_theme.dart';

/// The mark of an app in Agents → AI apps.
AiBrand? brandOfApp(AiApp a) => switch (a) {
      AiApp.chatgpt || AiApp.codex => AiBrand.openai,
      AiApp.claudeDesktop => AiBrand.claude,
      AiApp.claudeCode => AiBrand.claudecode,
      AiApp.geminiCli => AiBrand.gemini,
      AiApp.cursor => AiBrand.cursor,
      AiApp.vscode => AiBrand.copilot,
      AiApp.windsurf => AiBrand.windsurf,
      AiApp.zed => AiBrand.zed,
      AiApp.lmStudio => AiBrand.lmstudio,
      AiApp.grok => AiBrand.xai,
    };

/// A mark in a rounded tile. [brand] `null` draws the monogram of [label].
class AiLogo extends StatelessWidget {
  const AiLogo({super.key, required this.brand, required this.label, this.size = 36, this.circle = false});

  final AiBrand? brand;

  /// The name the monogram falls back to.
  final String label;
  final double size;

  /// A round tile (an avatar) instead of the rounded square of the lists.
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final mark = brand == null ? null : aiMarks[brand];
    final dark = XColors.isDark;
    final shape = circle
        ? const BoxDecoration(shape: BoxShape.circle)
        : BoxDecoration(borderRadius: BorderRadius.circular(size * 0.28));
    final tile = dark ? XColors.bg3 : XColors.bg1;
    return Container(
      key: Key('ai-logo-${brand?.name ?? 'monogram'}'),
      width: size,
      height: size,
      decoration: shape.copyWith(color: tile, border: Border.all(color: XColors.line)),
      alignment: Alignment.center,
      child: mark == null
          ? Text(
              _monogram(label),
              style: TextStyle(
                fontFamily: XFonts.sans,
                fontWeight: FontWeight.w600,
                fontSize: size * 0.36,
                color: XColors.textDim,
                height: 1,
              ),
            )
          : CustomPaint(
              size: Size.square(size * 0.58),
              painter: _MarkPainter(mark, dark ? mark.onDark : mark.onLight),
            ),
    );
  }

  static String _monogram(String s) {
    final parts = s.trim().split(RegExp(r'[\s_\-./·•|]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
    return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.mark, this.color);
  final AiMark mark;
  final Color color;

  static final _cache = <String, Path>{};

  @override
  void paint(Canvas canvas, Size size) {
    final path = _cache.putIfAbsent(mark.d, () => parseSvgPath(mark.d));
    final s = size.width / mark.viewBox;
    canvas.save();
    canvas.scale(s, s);
    canvas.drawPath(path..fillType = PathFillType.nonZero, Paint()..color = color..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.mark != mark || old.color != color;
}
