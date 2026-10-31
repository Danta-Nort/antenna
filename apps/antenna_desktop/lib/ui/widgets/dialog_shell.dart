// SPDX-License-Identifier: AGPL-3.0-only
// Dialog shell and the owner password prompt. Commands that change trust and links (invite, join, trust, approve,
// deny, pairing confirm/cancel) are accepted by the daemon only with the password, on every call (maintainer
// decision Q-12a). The UI does not remember the password.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';

Future<T?> showXDialog<T>(BuildContext context, WidgetBuilder builder, {bool dismissible = true}) => showDialog<T>(
      context: context,
      barrierDismissible: dismissible,
      barrierColor: XColors.scrim,
      builder: builder,
    );

/// Dialog panel: white, rounded, with a soft shadow (a thin glowing border in the dark theme); a title with an icon,
/// content and actions.
class XDialogShell extends StatelessWidget {
  const XDialogShell({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.leading,
    this.titleTag,
    this.subtitle,
    this.actions = const [],
    this.width = 560,
    this.onClose,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// Drawn instead of [icon] (an app's mark in Connect).
  final Widget? leading;

  /// A small tag right after the title (the Experimental tag, D-94).
  final Widget? titleTag;
  final Widget child;
  final List<Widget> actions;
  final double width;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: Container(
            decoration: xPanel(fill: XColors.bg1, border: XColors.isDark ? XColors.lineStrong : XColors.line, radius: XRadius.xl, glow: 1.6),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 12),
                ] else if (icon != null) ...[
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
                    child: Icon(icon, size: 18, color: XColors.accent),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: titleTag == null
                      ? Text(title, style: XText.h2)
                      // Inline after the last word, so a title that wraps keeps the tag next to it.
                      : Text.rich(
                          TextSpan(text: title, children: [
                            const WidgetSpan(child: SizedBox(width: 8)),
                            WidgetSpan(alignment: PlaceholderAlignment.middle, child: titleTag!),
                          ]),
                          style: XText.h2,
                        ),
                ),
                IconButton(
                  tooltip: context.l.commonClose,
                  onPressed: onClose ?? () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ]),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: XText.bodyDim),
              ],
              const SizedBox(height: 16),
              Flexible(child: SingleChildScrollView(child: child)),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
              ],
            ]),
          ),
        ),
      );
}

/// Owner password field inside a form.
class OwnerPasswordField extends StatefulWidget {
  const OwnerPasswordField({super.key, required this.controller, this.onSubmitted, this.autofocus = false});
  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<OwnerPasswordField> createState() => _OwnerPasswordFieldState();
}

class _OwnerPasswordFieldState extends State<OwnerPasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => TextField(
        key: const Key('owner-password'),
        controller: widget.controller,
        autofocus: widget.autofocus,
        obscureText: _obscure,
        enableSuggestions: false,
        autocorrect: false,
        style: XText.body.copyWith(fontFamily: XFonts.mono, letterSpacing: 2),
        decoration: InputDecoration(
          labelText: context.l.ownerPassword,
          helperText: context.l.ownerPasswordHelper,
          helperStyle: XText.monoSmall,
          prefixIcon: const Icon(Icons.key_outlined, size: 17),
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 17),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        onSubmitted: widget.onSubmitted,
      );
}

/// Ask for the owner password for one command. [action] says what exactly will be done (shown prominently). [note]
/// says why the password is asked when the owner expected Touch ID (D-102: 14 days, a fingerprint change…).
Future<String?> askOwnerPassword(BuildContext context,
        {required String action, String? detail, String? cli, String? note}) =>
    showXDialog<String>(context, (_) => _PasswordPrompt(action: action, detail: detail, cli: cli, note: note));

/// The prompt owns its text field's controller: the dialog's closing animation still draws the field after the
/// answer is returned, so the controller lives exactly as long as the dialog's widget.
class _PasswordPrompt extends StatefulWidget {
  const _PasswordPrompt({required this.action, this.detail, this.cli, this.note});
  final String action;
  final String? detail;
  final String? cli;
  final String? note;

  @override
  State<_PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<_PasswordPrompt> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => XDialogShell(
        title: context.l.commonConfirmWithPassword,
        icon: Icons.verified_user_outlined,
        width: 460,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonCancel)),
          FilledButton(
            key: const Key('password-ok'),
            onPressed: () => Navigator.pop(context, _c.text),
            child: Text(context.l.commonConfirm),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.note case final note?) ...[
            Row(key: const Key('password-note'), crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.fingerprint, size: 16, color: XColors.textDim),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(note, style: XText.bodyDim)),
            ]),
            const SizedBox(height: 12),
          ],
          Text(widget.action, style: XText.title),
          if (widget.detail != null) ...[const SizedBox(height: 8), Text(widget.detail!, style: XText.bodyDim)],
          if (widget.cli != null) ...[const SizedBox(height: 8), Text(widget.cli!, style: XText.monoSmall)],
          const SizedBox(height: 16),
          OwnerPasswordField(controller: _c, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        ]),
      );
}

/// Error line under a form.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.text, {super.key, this.detail});
  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.error_outline, size: 16, color: XColors.danger),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: XText.bodyDim.copyWith(color: XColors.danger))),
          ]),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: Text(detail!, style: XText.monoSmall),
            ),
        ]),
      );
}
