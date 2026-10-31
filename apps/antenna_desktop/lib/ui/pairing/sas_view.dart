// SPDX-License-Identifier: AGPL-3.0-only
// QR code of the link and showing/entering the verification code: digits or the same animal emoji (Q-6).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';

/// Name of a code animal for reading aloud, in the app language (the daemon accepts both English and Russian names).
extension SasGlyphName on SasGlyph {
  String name(AppLocalizations l) => switch (digit) {
        0 => l.sasAnimal0,
        1 => l.sasAnimal1,
        2 => l.sasAnimal2,
        3 => l.sasAnimal3,
        4 => l.sasAnimal4,
        5 => l.sasAnimal5,
        6 => l.sasAnimal6,
        7 => l.sasAnimal7,
        8 => l.sasAnimal8,
        _ => l.sasAnimal9,
      };
}

/// QR: dark modules on a light field, so that any camera can read it; the frame follows the app style.
class QrView extends StatelessWidget {
  const QrView(this.data, {super.key, this.size = 196});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: XColors.qrPaper,
        borderRadius: BorderRadius.circular(XRadius.l),
        border: Border.all(color: XColors.line),
        boxShadow: XColors.isDark
            ? [BoxShadow(color: XColors.accent.withValues(alpha: 0.35), blurRadius: 24, spreadRadius: -4)]
            : xSoftShadow(),
      ),
      child: CustomPaint(painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);
  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    final cell = size.width / n;
    final p = Paint()..color = XColors.qrInk;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (image.isDark(r, c)) {
          canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell + 0.4, cell + 0.4), p);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}

/// The "Digits / Emoji" switch.
class SasModeSwitch extends StatelessWidget {
  const SasModeSwitch({super.key, required this.emoji, required this.onChanged});
  final bool emoji;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<bool>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: XText.label,
          side: BorderSide(color: XColors.lineStrong),
          selectedBackgroundColor: XColors.accentSoft,
          selectedForegroundColor: XColors.accent,
          foregroundColor: XColors.textDim,
        ),
        segments: [
          ButtonSegment(value: false, label: Text(context.l.sasDigits)),
          ButtonSegment(value: true, label: Text(context.l.sasEmoji)),
        ],
        selected: {emoji},
        onSelectionChanged: (s) => onChanged(s.first),
      );
}

/// The large code on side A: digits in groups of 3+3, or 6 emoji with their names (read out by voice).
class SasDisplay extends StatelessWidget {
  const SasDisplay({super.key, required this.code, required this.emoji});
  final String code;
  final bool emoji;

  @override
  Widget build(BuildContext context) {
    final glyphs = sasGlyphsOf(code);
    final box = xGlow(radius: XRadius.l, strength: 0.7, fill: XColors.bg0);
    if (!emoji || glyphs == null) {
      return Container(
        key: const Key('sas-digits'),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: box,
        alignment: Alignment.center,
        child: Text('${code.substring(0, 3)} ${code.substring(3)}', style: XText.sas),
      );
    }
    return Container(
      key: const Key('sas-emoji'),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: box,
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        for (final g in glyphs)
          Column(mainAxisSize: MainAxisSize.min, children: [
            SasEmoji(g.emoji, size: 34),
            const SizedBox(height: 8),
            Text(g.name(context.l), style: XText.monoSmall.copyWith(color: XColors.textDim)),
          ]),
      ]),
    );
  }
}

/// Code emoji use a bundled monochrome font, so both sides see the same glyphs on any OS.
class SasEmoji extends StatelessWidget {
  const SasEmoji(this.emoji, {super.key, this.size = 28, this.color});
  final String emoji;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        emoji,
        style: TextStyle(fontFamily: 'SAS Emoji', fontSize: size, height: 1.1, color: color ?? XColors.text),
      );
}

/// Code entry: 6 digits in a field or 6 taps on animals (the daemon accepts both forms). On side B it is the code
/// heard from A; on side A, when confirming, it is the code B read back aloud.
class SasInput extends StatefulWidget {
  const SasInput({
    super.key,
    required this.onSubmit,
    this.enabled = true,
    this.title,
    this.submitLabel,
    this.footer,
    this.allowIncomplete = false,
    this.submitKey = const Key('sas-submit'),
  });
  final ValueChanged<String> onSubmit;
  final bool enabled;

  /// Field title; defaults to "the code from the invite's owner" (side B).
  final String? title;

  /// Button label; defaults to "Check code".
  final String? submitLabel;

  /// Shown between the field and the button (for example the owner password and an error).
  final Widget? footer;

  /// The button stays enabled with an incomplete code (the daemon then checks it and reports the error).
  final bool allowIncomplete;
  final Key submitKey;

  @override
  State<SasInput> createState() => _SasInputState();
}

class _SasInputState extends State<SasInput> {
  bool _emoji = false;
  final _digits = TextEditingController();
  final List<SasGlyph> _picked = [];

  @override
  void dispose() {
    _digits.dispose();
    super.dispose();
  }

  String get _code => _emoji ? _picked.map((g) => g.emoji).join() : _digits.text;
  bool get _complete => _emoji ? _picked.length == sasLength : RegExp(r'^\d{6}$').hasMatch(_digits.text);

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(widget.title ?? context.l.sasInputTitle, style: XText.label)),
        SasModeSwitch(emoji: _emoji, onChanged: (v) => setState(() => _emoji = v)),
      ]),
      const SizedBox(height: 12),
      if (!_emoji)
        TextField(
          key: const Key('sas-input'),
          controller: _digits,
          enabled: widget.enabled,
          autofocus: true,
          maxLength: 6,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: XText.sasCompact,
          decoration: const InputDecoration(counterText: '', hintText: '••••••'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _complete || widget.allowIncomplete ? widget.onSubmit(_code) : null,
        )
      else ...[
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: xPanel(fill: XColors.bg2, border: XColors.lineStrong, radius: XRadius.m),
          child: Row(children: [
            for (var i = 0; i < sasLength; i++)
              Expanded(
                child: Center(
                  child: i < _picked.length
                      ? SasEmoji(_picked[i].emoji, size: 30)
                      : Container(width: 18, height: 2, color: XColors.lineStrong),
                ),
              ),
            IconButton(
              tooltip: context.l.sasErase,
              onPressed: _picked.isEmpty ? null : () => setState(_picked.removeLast),
              icon: const Icon(Icons.backspace_outlined, size: 18),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 5,
          shrinkWrap: true,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 1.5,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final g in sasGlyphs)
              InkWell(
                key: Key('sas-key-${g.digit}'),
                onTap: !widget.enabled || _picked.length >= sasLength ? null : () => setState(() => _picked.add(g)),
                borderRadius: BorderRadius.circular(XRadius.s),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(XRadius.s),
                    border: Border.all(color: XColors.line),
                    color: XColors.bg2,
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SasEmoji(g.emoji, size: 22),
                    const SizedBox(height: 2),
                    Text(g.name(context.l), style: XText.monoSmall.copyWith(fontSize: 11)),
                  ]),
                ),
              ),
          ],
        ),
      ],
      if (widget.footer != null) ...[const SizedBox(height: 16), widget.footer!],
      const SizedBox(height: 16),
      FilledButton(
        key: widget.submitKey,
        onPressed: widget.enabled && (_complete || widget.allowIncomplete) ? () => widget.onSubmit(_code) : null,
        child: Text(widget.submitLabel ?? context.l.sasCheckCode),
      ),
    ]);
  }
}
