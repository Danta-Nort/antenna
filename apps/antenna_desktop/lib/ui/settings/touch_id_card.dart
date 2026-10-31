// SPDX-License-Identifier: AGPL-3.0-only
// Settings → Security → "Use Touch ID" (D-102, experimental): one line, its "?" (what it does, when the password is
// still asked and when next), and the switch. Turning it on opens a dialog that says what happens and asks the
// password, then one touch enrolls this Mac's Secure Enclave key; turning it off removes the key from the daemon and
// from this Mac, with no password (it only takes a way in away, D-84). Shown only on a Mac with Touch ID and a daemon
// that speaks x-control/7.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/section_page.dart';
import 'settings_page.dart' show SettingRow;

class TouchIdCard extends StatefulWidget {
  const TouchIdCard({super.key});

  @override
  State<TouchIdCard> createState() => _TouchIdCardState();
}

class _TouchIdCardState extends State<TouchIdCard> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final m = AppScope.read(context);
      await m.refreshTouchId();
      await m.refreshOwnerKeys();
    });
  }

  Future<void> _set(bool on) async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() => _error = null);
    if (on) {
      await showTouchIdEnrollDialog(context);
      return;
    }
    final err = await m.disableTouchId();
    if (mounted && err != null) setState(() => _error = describeError(l, err));
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    if (!m.touchIdOffered) return const SizedBox.shrink();
    final due = m.passwordDueMs;
    final dueText = !m.touchIdOn
        ? null
        : due == null || due <= m.now().millisecondsSinceEpoch
            ? l.touchIdPasswordDueNow
            : l.touchIdPasswordDue(formatDate(l, DateTime.fromMillisecondsSinceEpoch(due)));
    final notes = <String>[
      if (m.touchIdFingerprintsChanged) l.touchIdFingerprintsChanged,
      if (m.touchIdOn && (!m.touchIdStatus.available || m.touchIdPaused)) l.touchIdUnavailableNow,
      if (m.touchIdOn && !(m.ownerKeyRecord?.unlock ?? false)) l.touchIdNoUnlock,
    ];
    return SectionCard(
      key: const Key('touchid-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingRow(
          id: 'touchid',
          title: l.touchIdSetting,
          titleTag: const ExperimentalTag(),
          help: l.touchIdSettingHint,
          helpExtra: dueText == null
              ? null
              : Text(dueText, key: const Key('touchid-due'), style: XText.meta.copyWith(color: XColors.textDim)),
          control: Switch(
            key: const Key('touchid-switch'),
            value: m.touchIdOn,
            onChanged: m.touchIdBusy ? null : _set,
          ),
        ),
        // What one touch confirms, and when the password is still asked (D-131), said where it is turned on.
        if (m.touchIdOn)
          Padding(
            key: const Key('touchid-covers'),
            padding: const EdgeInsets.only(top: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.touchIdCoversTitle, style: XText.label.copyWith(color: XColors.text)),
              const SizedBox(height: 4),
              Text(l.touchIdCovers, style: XText.bodyDim),
              const SizedBox(height: 8),
              Text(l.touchIdCoversPassword, style: XText.meta.copyWith(color: XColors.textDim)),
            ]),
          ),
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.fingerprint, size: 16, color: XColors.warn),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(n, style: XText.bodyDim)),
            ]),
          ),
        if (_error != null) ErrorLine(_error!),
      ]),
    );
  }
}

/// "Turn on Touch ID": what happens, when the password is still asked, the password, then one touch.
Future<bool?> showTouchIdEnrollDialog(BuildContext context) =>
    showXDialog<bool>(context, (_) => const TouchIdEnrollDialog());

class TouchIdEnrollDialog extends StatefulWidget {
  const TouchIdEnrollDialog({super.key});

  @override
  State<TouchIdEnrollDialog> createState() => _TouchIdEnrollDialogState();
}

class _TouchIdEnrollDialogState extends State<TouchIdEnrollDialog> {
  final _password = TextEditingController();
  Object? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _enroll() async {
    final m = AppScope.read(context);
    final l = context.l;
    final pw = _password.text;
    if (pw.isEmpty) return;
    setState(() => _error = null);
    final err = await m.enrollTouchId(pw, reason: l.touchIdReasonEnroll);
    _password.clear();
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
    } else {
      setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final err = _error;
    return XDialogShell(
      title: l.touchIdEnrollTitle,
      icon: Icons.fingerprint,
      titleTag: const ExperimentalTag(),
      width: 520,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.commonCancel)),
        FilledButton.icon(
          key: const Key('touchid-enroll'),
          onPressed: m.touchIdBusy ? null : _enroll,
          icon: const Icon(Icons.fingerprint, size: 18),
          label: Text(l.touchIdEnrollButton),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.touchIdEnrollBody, style: XText.body),
        const SizedBox(height: 12),
        _Point(Icons.key_outlined, l.touchIdEnrollPassword),
        const SizedBox(height: 8),
        _Point(Icons.back_hand_outlined, l.touchIdEnrollWarning),
        if (!m.touchIdStatus.hpke) ...[
          const SizedBox(height: 8),
          _Point(Icons.lock_outline, l.touchIdEnrollNoHpke),
        ],
        const SizedBox(height: 16),
        OwnerPasswordField(controller: _password, autofocus: true, onSubmitted: (_) => _enroll()),
        const SizedBox(height: 8),
        Text(l.touchIdEnrollStep, key: const Key('touchid-enroll-step'), style: XText.meta),
        if (err != null) ErrorLine(describeError(l, err), detail: errorDetail(err)),
      ]),
    );
  }
}

/// One line of the dialog: a small icon and the text.
class _Point extends StatelessWidget {
  const _Point(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: XColors.textDim)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: XText.bodyDim)),
      ]);
}
