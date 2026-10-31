// SPDX-License-Identifier: AGPL-3.0-only
// The one "Secure" indicator of the conversation header (reference v3), instead of the cluster of the E2E · PQ badge
// and the history chip. One word says the state; its popover says in plain words what it rests on (end-to-end
// encryption, post-quantum protection, the transport, the history verification with its fingerprint), with "Verify
// now", a way to the contact card, and the raw TLS and libsignal facts behind "Technical details". Everything comes
// from the daemon's facts, the same as the card's; nothing is claimed that the daemon did not report, and every
// warning the old badges showed is still there: in the word, its color, or the popover.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/facts.dart';
import '../../state/format.dart';
import '../../state/messages.dart' show describeError;
import '../../state/trust.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../pairing/sas_view.dart';
import '../widgets/popover.dart';

/// The word, its icon and its color for a [SecureState].
(String, IconData, Color) secureLook(AppLocalizations l, SecureState s) => switch (s) {
      SecureState.secure => (l.secureChip, Icons.verified_user_rounded, XColors.ok),
      SecureState.encrypted => (l.secureChipEncrypted, Icons.lock_outline_rounded, XColors.textDim),
      SecureState.unconfirmed => (l.secureChipUnconfirmed, Icons.shield_outlined, XColors.textMute),
      SecureState.mismatch => (l.secureChipMismatch, Icons.gpp_bad_outlined, XColors.danger),
      SecureState.rekey => (l.secureChipRekey, Icons.gpp_maybe_outlined, XColors.warn),
    };

class SecureIndicator extends StatelessWidget {
  const SecureIndicator(this.c, {super.key, this.onDetails});
  final ContactInfo c;

  /// Opens the contact card with every fact (`null`: the card is open or does not fit).
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final state = SecureState.of(c);
    final (text, icon, color) = secureLook(l, state);
    return XPopover(
      key: const Key('secure-indicator'),
      cardKey: const Key('secure-details'),
      label: l.secureDetailsLabel,
      width: 360,
      radius: 20,
      content: (context, close) => SecureDetails(c, onDetails: onDetails == null ? null : () {
        close();
        onDetails!();
      }),
      child: Container(
        key: Key('secure-${state.name}'),
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
        decoration: BoxDecoration(
          color: Color.alphaBlend(color.withValues(alpha: XColors.isDark ? 0.14 : 0.10), XColors.bg1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text, style: XText.label.copyWith(color: color, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// The popover: one line per fact the indicator rests on, in plain words.
class SecureDetails extends StatefulWidget {
  const SecureDetails(this.c, {super.key, this.onDetails});
  final ContactInfo c;
  final VoidCallback? onDetails;

  @override
  State<SecureDetails> createState() => _SecureDetailsState();
}

/// What "Verify now" found, once the daemon answered.
enum _VerifyOutcome { ok, mismatch, error }

class _SecureDetailsState extends State<SecureDetails> {
  bool _technical = false;
  bool _verifying = false;

  /// The last "Verify now" result in this popover (cleared when it opens again).
  (_VerifyOutcome, Object?)? _verifyResult;

  Future<void> _verify() async {
    final m = AppScope.read(context);
    setState(() {
      _verifying = true;
      _verifyResult = null;
    });
    final err = await m.verify(widget.c.linkId);
    if (!mounted) return;
    setState(() {
      _verifying = false;
      if (err != null) {
        _verifyResult = (_VerifyOutcome.error, err);
      } else {
        final state = (m.contactById(widget.c.linkId) ?? widget.c).history?.state;
        final diverged = state == 'mismatch' || state == 'rolled_back' || state == 'peer_rolled_back';
        _verifyResult = (diverged ? _VerifyOutcome.mismatch : _VerifyOutcome.ok, null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = widget.c;
    final f = PqFacts(c);
    final h = c.history;
    final state = SecureState.of(c);
    final (_, icon, color) = secureLook(l, state);
    final glyphs = h?.fingerprintDigits == null ? null : digitGlyphs(h!.fingerprintDigits!);
    final (historyText, historyNote, historyColor) = switch (h?.state) {
      'verified' => (
          l.historyVerified,
          glyphs == null
              ? l.historyVerifiedTooltip
              : l.historyFingerprintTooltip(glyphs.map((g) => g.name(l)).join(' '), h!.fingerprintDigits!),
          XColors.ok
        ),
      'syncing' => (l.secureHistorySyncing, l.historySyncingTooltip, XColors.textMute),
      'mismatch' => (l.secureChipMismatch, l.historyMismatchTooltip, XColors.danger),
      'rolled_back' => (l.secureChipRekey, l.historyRolledBackTooltip, XColors.danger),
      'peer_rolled_back' => (l.secureHistoryPeerRolledBack, l.historyPeerRolledBackTooltip, XColors.warn),
      null => (l.secureHistoryNone, null, XColors.textMute),
      _ => (l.secureHistoryUnchecked, l.historyUncheckedTooltip, XColors.textMute),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(state == SecureState.secure ? l.secureTitle : l.secureTitleOther,
              style: XText.body.copyWith(fontWeight: FontWeight.w600)),
        ),
      ]),
      const SizedBox(height: 12),
      _Fact(
        key: const Key('secure-e2e'),
        state: f.hasE2e ? _FactState.ok : _FactState.no,
        title: f.hasE2e ? l.secureE2e : l.secureE2eNone,
      ),
      _Fact(
        key: const Key('secure-pq'),
        state: f.pq ? (f.spqrComplete ? _FactState.ok : _FactState.pending) : _FactState.no,
        title: f.pq ? (f.spqrComplete ? l.securePq : l.securePqNegotiating) : l.securePqNo,
      ),
      _Fact(
        key: const Key('secure-transport'),
        state: _FactState.info,
        icon: c.netMode == 'relay_only' ? Icons.cell_tower_outlined : Icons.swap_horiz_rounded,
        title: netModeLabel(l, c.netMode),
        note: netModeHint(l, c.netMode),
      ),
      _Fact(
        key: const Key('secure-history'),
        state: h?.verified ?? false ? _FactState.ok : _FactState.info,
        color: historyColor,
        icon: switch (h?.state) {
          'verified' => null,
          'mismatch' || 'rolled_back' => Icons.error_outline_rounded,
          'peer_rolled_back' => Icons.history_rounded,
          'syncing' => Icons.sync_rounded,
          _ => Icons.help_outline_rounded,
        },
        title: historyText,
        note: historyNote,
        trailing: [
          if (h != null && h.verified && glyphs != null)
            for (final g in glyphs)
              Padding(padding: const EdgeInsets.only(left: 4), child: SasEmoji(g.emoji, size: 14, color: XColors.ok)),
          if (h != null && h.verified && h.atMs != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(hhmm(DateTime.fromMillisecondsSinceEpoch(h.atMs!)), style: XText.meta),
            ),
        ],
      ),
      // The raw facts, for whoever wants to check them: hidden until asked for.
      InkWell(
        key: const Key('secure-technical'),
        onTap: () => setState(() => _technical = !_technical),
        borderRadius: BorderRadius.circular(XRadius.s),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(_technical ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 16, color: XColors.textDim),
            const SizedBox(width: 4),
            Text(l.secureTechnical, style: XText.label),
          ]),
        ),
      ),
      if (_technical)
        Container(
          key: const Key('secure-facts'),
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.m)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (k, v) in f.lines(l))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 120, child: Text(k, style: XText.monoSmall)),
                  Expanded(child: SelectableText(v, style: XText.monoSmall.copyWith(color: XColors.text))),
                ]),
              ),
            const SizedBox(height: 4),
            Text(l.badgeFactsSource, style: XText.meta),
          ]),
        ),
      const SizedBox(height: 8),
      Row(children: [
        if (h != null)
          TextButton(
            key: const Key('secure-verify'),
            onPressed: _verifying ? null : _verify,
            // Idle looks exactly as before; only while it runs does a spinner join the label.
            child: _verifying
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Text(l.secureVerifyChecking),
                  ])
                : Text(l.secureVerifyNow),
          ),
        const Spacer(),
        if (widget.onDetails != null)
          TextButton.icon(
            key: const Key('secure-card'),
            onPressed: widget.onDetails,
            icon: const Icon(Icons.info_outline_rounded, size: 16),
            label: Text(l.secureOpenCard),
          ),
      ]),
      if (_verifyResult != null)
        Padding(
          key: const Key('secure-verify-result'),
          padding: const EdgeInsets.only(top: 4),
          child: _VerifyResultLine(_verifyResult!),
        ),
    ]);
  }
}

/// "Checked just now: …" under the "Verify now" button: a spinner told the owner it ran, this says what it found.
class _VerifyResultLine extends StatelessWidget {
  const _VerifyResultLine(this.result);
  final (_VerifyOutcome, Object?) result;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final (outcome, error) = result;
    final (icon, color, text) = switch (outcome) {
      _VerifyOutcome.ok => (Icons.check_circle_rounded, XColors.ok, l.secureVerifyResultOk),
      _VerifyOutcome.mismatch => (Icons.error_outline_rounded, XColors.danger, l.secureVerifyResultMismatch),
      _VerifyOutcome.error =>
        (Icons.error_outline_rounded, XColors.warn, l.secureVerifyResultError(describeError(l, error!))),
    };
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 14, color: color)),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: XText.meta.copyWith(color: color))),
    ]);
  }
}

enum _FactState { ok, pending, no, info }

class _Fact extends StatelessWidget {
  const _Fact({
    super.key,
    required this.state,
    required this.title,
    this.note,
    this.icon,
    this.color,
    this.trailing = const [],
  });
  final _FactState state;
  final String title;
  final String? note;
  final IconData? icon;
  final Color? color;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final c = color ??
        switch (state) {
          _FactState.ok => XColors.ok,
          _FactState.pending => XColors.warn,
          _FactState.no => XColors.textMute,
          _FactState.info => XColors.textDim,
        };
    final i = icon ??
        switch (state) {
          _FactState.ok => Icons.check_circle_rounded,
          _FactState.pending => Icons.timelapse_rounded,
          _FactState.no => Icons.remove_circle_outline_rounded,
          _FactState.info => Icons.info_outline_rounded,
        };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(i, size: 16, color: c)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(title, style: XText.body.copyWith(color: XColors.text))),
              ...trailing,
            ]),
            if (note != null && note!.isNotEmpty) Text(note!, style: XText.meta),
          ]),
        ),
      ]),
    );
  }
}
