// SPDX-License-Identifier: AGPL-3.0-only
// History verification and rekey (SPEC §8, x-control/2, CONTROL §12): the banners under the chat header: mismatch
// (read-only, accept, restore our copy), rollback of our own state and rollback on the contact's side (rekey with two
// codes), conflicting proposals. The verification state and its 3-emoji fingerprint are in the header's "Secure"
// indicator (`secure_indicator.dart`).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../pairing/sas_view.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';

/// Banners under the chat header: what about the link's history needs the owner's decision.
class HistoryBanners extends StatelessWidget {
  const HistoryBanners(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final h = c.history;
    final r = m.rekeys[c.linkId];
    final rows = <Widget>[];
    if (r != null && r.stage == RekeyStage.conflict) rows.add(const _ConflictBanner());
    if (h != null && h.mismatch) rows.add(_MismatchBanner(c, h));
    final rekeyActive = r != null && r.stage != RekeyStage.idle && r.stage != RekeyStage.done && r.stage != RekeyStage.conflict;
    if ((h != null && (h.rolledBack || h.peerRolledBack)) || rekeyActive) rows.add(RekeyPanel(c));
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(children: rows);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.icon, required this.title, required this.child, this.actions = const []});
  final Color color;
  final IconData icon;
  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: xGlow(
          radius: XRadius.m,
          color: color,
          strength: 0.9,
          fill: Color.alphaBlend(color.withValues(alpha: 0.10), XColors.bg1),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: XText.title.copyWith(color: color)),
              const SizedBox(height: 4),
              child,
            ]),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final a in actions) Padding(padding: const EdgeInsets.only(bottom: 8), child: a),
            ]),
          ],
        ]),
      );
}

String _whoChanged(AppLocalizations l, String? w) => switch (w) {
      'me' => l.historyChangedMine,
      'contact' => l.historyChangedContact,
      'both' => l.historyChangedBoth,
      _ => l.historyChangedUnknown,
    };

String _reason(AppLocalizations l, String? r) => switch (r) {
      'local_copy_damaged' => l.historyReasonLocalDamaged,
      'contact_copy_damaged' => l.historyReasonContactDamaged,
      'signature_invalid' => l.historyReasonSignature,
      'two_signed_versions' => l.historyReasonTwoVersions,
      'contact_reports_difference' => l.historyReasonContactSays,
      null => '',
      _ => r,
    };

class _MismatchBanner extends StatefulWidget {
  const _MismatchBanner(this.c, this.h);
  final ContactInfo c;
  final HistoryStatus h;

  @override
  State<_MismatchBanner> createState() => _MismatchBannerState();
}

class _MismatchBannerState extends State<_MismatchBanner> {
  /// The daemon's explanation (English, technical) is shown only under "Details", not repeated under the app's text.
  bool _details = false;

  ContactInfo get c => widget.c;
  HistoryStatus get h => widget.h;

  Future<void> _accept(BuildContext context) async {
    final m = AppScope.read(context);
    final (_, err) = await confirmOwner(
      context,
      action: context.l.historyAcceptAction,
      detail: context.l.historyAcceptDetail,
      cli: 'antenna verify ${c.label} --accept',
      run: (auth) => m.verify(c.linkId, accept: true, auth: auth),
    );
    if (err != null && context.mounted) _snack(context, describeError(context.l, err));
  }

  @override
  Widget build(BuildContext context) {
    final p = h.place;
    final l = context.l;
    final where = p == null
        ? ''
        : '${p.author == 'me' ? l.historyPlaceMine(p.n) : l.historyPlaceContact(p.n)}'
            '${p.ts == null ? '' : ' (${formatDateTime(l, DateTime.fromMillisecondsSinceEpoch(p.ts!))})'}'
            '${p.lamport == null ? '' : ', lamport ${p.lamport}'}';
    final m = AppScope.read(context);
    return _Banner(
      color: h.sendBlocked ? XColors.danger : XColors.warn,
      icon: Icons.report_gmailerrorred_outlined,
      title: h.sendBlocked
          ? l.historyDivergedReadOnly
          : (h.accepted ? l.historyAcceptedByYou : l.historyDiverged),
      actions: [
        if (h.reason == 'local_copy_damaged')
          OutlinedButton(
            key: const Key('history-repair'),
            onPressed: () async {
              final err = await m.verify(c.linkId, repair: true);
              if (err != null && context.mounted) _snack(context, describeError(context.l, err));
            },
            child: Text(l.historyRepair),
          ),
        if (h.sendBlocked && !h.accepted)
          TextButton(key: const Key('history-accept'), onPressed: () => _accept(context), child: Text(l.historyAccept)),
        TextButton(onPressed: () => m.verify(c.linkId), child: Text(l.historyVerifyAgain)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (where.isNotEmpty) Text(l.historyPlace(where), style: XText.mono.copyWith(color: XColors.text)),
        const SizedBox(height: 2),
        Text(
          '${_whoChanged(l, h.whoChanged)}${h.reason == null ? '' : ' ${l.historyReason(_reason(l, h.reason))}'}',
          style: XText.bodyDim,
        ),
        if (h.detail.isNotEmpty) ...[
          const SizedBox(height: 2),
          InkWell(
            key: const Key('history-details'),
            onTap: () => setState(() => _details = !_details),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                _details ? l.historyHideDetails : l.historyShowDetails,
                style: XText.monoSmall.copyWith(color: XColors.accent),
              ),
            ),
          ),
          if (_details) SelectableText(h.detail, style: XText.monoSmall),
        ],
      ]),
    );
  }
}

class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner();

  @override
  Widget build(BuildContext context) => _Banner(
        color: XColors.danger,
        icon: Icons.gpp_bad_outlined,
        title: context.l.rekeyConflictTitle,
        child: Text(
          context.l.rekeyConflictBody,
          style: XText.bodyDim,
        ),
      );
}

/// Rekey after a rollback: two codes, each owner types the other's code (CONTROL §12, PROTOCOL §17).
class RekeyPanel extends StatefulWidget {
  const RekeyPanel(this.c, {super.key});
  final ContactInfo c;

  @override
  State<RekeyPanel> createState() => _RekeyPanelState();
}

class _RekeyPanelState extends State<RekeyPanel> {
  final _auth = OwnerAuthController();

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  Future<void> _propose() async {
    final m = AppScope.read(context);
    await confirmOwner(
      context,
      action: context.l.rekeyProposeAction(widget.c.label),
      detail: context.l.rekeyProposeDetail,
      cli: 'antenna rekey ${widget.c.label}',
      run: (auth) => m.rekey(widget.c.linkId, auth),
    );
  }

  Future<void> _submit(String code) async {
    final m = AppScope.read(context);
    final l = context.l;
    final auth = _auth.auth(m, touchIdConfirmReason(l, l.rekeyProposeAction(widget.c.label)));
    _auth.password.clear();
    final err = await m.rekey(widget.c.linkId, auth, code: code);
    if (mounted) _auth.fellBack(l, m, err);
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final c = widget.c;
    final h = c.history;
    final f = m.rekeys[c.linkId] ?? RekeyFlow();
    final l = context.l;
    final stage = f.stage == RekeyStage.idle
        ? (h?.peerRolledBack ?? false ? RekeyStage.enterFirstCode : RekeyStage.idle)
        : f.stage;
    final err = f.error == null ? null : ErrorLine(describeRekeyError(l, f.error!), detail: errorDetail(f.error!));
    Widget codeInput(String title) => SasInput(
          key: ValueKey('rekey-input-$stage'),
          title: title,
          submitLabel: _auth.usesTouch(m) ? l.commonConfirm : l.commonConfirmWithPassword,
          submitKey: const Key('rekey-submit'),
          enabled: !f.busy,
          onSubmit: _submit,
          footer: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            OwnerAuthField(controller: _auth),
            ?err,
          ]),
        );
    Widget showCode(String what) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(what, style: XText.bodyDim),
          const SizedBox(height: 8),
          if (f.code != null) SasDisplay(code: f.code!, emoji: false),
          if (f.code != null && sasGlyphsOf(f.code!) != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                l.rekeyOrAnimals(sasGlyphsOf(f.code!)!.map((g) => g.name(l)).join(' · ')),
                style: XText.monoSmall.copyWith(color: XColors.textDim),
              ),
            ),
          ],
        ]);
    final rollbackText = switch (h?.rollback) {
      'contact_numbers' => l.rekeyRollbackContactNumbers,
      _ => l.rekeyRollbackLocal,
    };
    final (title, body, actions) = switch (stage) {
      RekeyStage.idle => (
          l.rekeyNeeded,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(rollbackText, style: XText.bodyDim),
            ?err,
          ]),
          <Widget>[
            FilledButton(
              key: const Key('rekey-propose'),
              onPressed: f.busy ? null : _propose,
              child: Text(l.rekeyPropose),
            ),
          ]
        ),
      RekeyStage.myCodeShown => (
          l.rekeyStep1Title,
          showCode(l.rekeyStep1Body),
          <Widget>[]
        ),
      RekeyStage.enterSecondCode => (
          l.rekeyStep2Title,
          codeInput(l.rekeyContactCode),
          <Widget>[]
        ),
      RekeyStage.enterFirstCode => (
          l.rekeyContactAsksTitle,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              l.rekeyContactAsksBody,
              style: XText.bodyDim,
            ),
            const SizedBox(height: 8),
            codeInput(l.rekeyContactCode),
          ]),
          <Widget>[]
        ),
      RekeyStage.secondCodeShown => (
          l.rekeyReadBackTitle,
          showCode(l.rekeyReadBackBody),
          <Widget>[]
        ),
      RekeyStage.done || RekeyStage.conflict => ('', const SizedBox.shrink(), <Widget>[]),
    };
    if (title.isEmpty) return const SizedBox.shrink();
    return _Banner(
      color: stage == RekeyStage.idle ? XColors.danger : XColors.warn,
      icon: Icons.key_outlined,
      title: title,
      actions: actions,
      child: body,
    );
  }
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
