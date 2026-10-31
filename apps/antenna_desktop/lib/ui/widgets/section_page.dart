// SPDX-License-Identifier: AGPL-3.0-only
// Section page (Agents, Files, Settings): a large title, an explanation, centered content with margins.

import 'package:flutter/material.dart';

import '../../theme/x_theme.dart';

class SectionPage extends StatelessWidget {
  const SectionPage(
      {super.key,
      required this.title,
      this.subtitle,
      this.action,
      this.maxWidth = 860,
      this.children = const [],
      this.body});
  final String title;

  /// The content's width at most.
  final double maxWidth;
  final String? subtitle;
  final Widget? action;
  final List<Widget> children;

  /// Instead of [children] in a scrolling list: one widget that fills the rest of the page (the agent map's canvas,
  /// which pans and zooms by itself), the whole width.
  final Widget? body;

  Widget _header() => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: XText.h1),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle!, style: XText.body.copyWith(color: XColors.textDim)),
            ],
          ]),
        ),
        if (action != null) ...[const SizedBox(width: 24), action!],
      ]);

  @override
  Widget build(BuildContext context) {
    if (body case final b?) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(40, 32, 40, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(),
          const SizedBox(height: 24),
          Expanded(child: b),
        ]),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(padding: const EdgeInsets.fromLTRB(40, 32, 40, 32), children: [
          _header(),
          const SizedBox(height: 24),
          ...children,
        ]),
      ),
    );
  }
}

/// Card inside a page: white, thin border, soft shadow (light theme).
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: padding,
        decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, glow: 0.6),
        child: child,
      );
}
