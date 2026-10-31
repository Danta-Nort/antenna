// SPDX-License-Identifier: AGPL-3.0-only
// Link card: trust level (changing it needs the password), network mode, encryption and link facts, all from
// `antenna contacts`; the log of actions taken on the contact's requests comes from `antenna log`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/facts.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../state/owner_auth.dart';
import '../../state/threads.dart';
import '../../state/trust.dart';
import '../../theme/x_theme.dart';
import '../agents/wake_ui.dart';
import '../app_scope.dart';
import '../files/media_files.dart';
import '../pairing/sas_view.dart';
import '../pictures/chat_picture_picker.dart' show showChatPicturePicker;
import '../security/owner_confirm.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/agent_logo.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/self_level.dart';
import '../widgets/trust_picker.dart';
import '../widgets/x_buttons.dart';
import 'file_prefs_section.dart';

/// The card in a dialog, for windows too narrow for the inline panel next to the conversation (Code mode's docked
/// terminals can leave less than the 980 px the side-by-side layout needs): the info button and the header's name
/// and avatar stay reachable at every width by opening this instead.
Future<void> showContactCardDialog(BuildContext context) => showXDialog<void>(context, (ctx) {
      final c = AppScope.of(ctx).selected;
      final height = (MediaQuery.sizeOf(ctx).height * 0.75).clamp(360.0, 640.0);
      return XDialogShell(
        key: const Key('contact-card-dialog'),
        title: c?.label ?? ctx.l.chatShowCard,
        icon: Icons.person_outline_rounded,
        width: 420,
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l.commonClose))],
        child: SizedBox(height: height, child: const ContactPanel()),
      );
    });

class ContactPanel extends StatelessWidget {
  const ContactPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final c = m.selected;
    if (c == null) return const SizedBox.shrink();
    return ColoredBox(
      color: XColors.bg1,
      child: ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 24), children: [
        ContactHead(c, agent: c.peerKind == 'agent'),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('card-media'),
            onPressed: () => showMediaAndFiles(context, c, k: ThreadKey.person),
            icon: const Icon(Icons.perm_media_outlined, size: 16),
            label: Text(context.l.cardMediaFiles(m.filesOfLink(c.linkId).length)),
          ),
        ),
        const SizedBox(height: 24),
        TrustSection(c, key: ValueKey('trust-${c.linkId}')),
        const SizedBox(height: 24),
        NetSection(c),
        const SizedBox(height: 24),
        CryptoSection(c),
        const SizedBox(height: 24),
        HistorySection(c),
        const SizedBox(height: 24),
        AuditSection(c, key: ValueKey('log-${c.linkId}-${c.trust}')),
        if (c.trust >= 5) ...[const SizedBox(height: 24), FilePrefsSection(c)],
        const SizedBox(height: 24),
        ContactAgentsSection(c),
        const SizedBox(height: 24),
        WakeContactSection(c),
        const SizedBox(height: 24),
        LinkSection(c),
        const SizedBox(height: 24),
        RevokeSection(c),
      ]),
    );
  }
}

class ContactHead extends StatelessWidget {
  const ContactHead(this.c, {super.key, this.agent = false});
  final ContactInfo c;
  final bool agent;

  @override
  Widget build(BuildContext context) {
    final created = DateTime.fromMillisecondsSinceEpoch(c.createdMs);
    return Row(children: [
      XAvatar(c.label, size: 56, agent: agent, picture: AppScope.maybeOf(context)?.pictureOfContact(c.linkId)),
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(c.label, overflow: TextOverflow.ellipsis, style: XText.h2.copyWith(fontSize: 20))),
            IconButton(
              key: const Key('contact-rename'),
              tooltip: context.l.cardRenameTooltip,
              onPressed: () => showContactRename(context, c),
              icon: const Icon(Icons.edit_outlined, size: 16),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            '${c.role == 'inviter' ? context.l.commonYouInvited : context.l.commonYouJoined} · ${formatDate(context.l, created)}',
            style: XText.monoSmall.copyWith(color: XColors.textDim),
          ),
          if (c.peerKind == 'agent' || c.peerKind == 'mixed') ...[const SizedBox(height: 8), PeerKindTag(c)],
        ]),
      ),
    ]);
  }
}

/// Rename a contact: the label is the owner's own (SPEC §5); also "Rename contact…" of the person chat's menu.
Future<void> showContactRename(BuildContext context, ContactInfo c) async {
  final label = await showXDialog<String>(context, (ctx) => _ContactRenameDialog(c));
  if (label == null || label.isEmpty || label == c.label || !context.mounted) return;
  final err = await AppScope.read(context).rename(c.linkId, label);
  if (err != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
  }
}

/// The dialog owns its field's controller: the route still draws the field while it closes, so a controller disposed
/// right after `showDialog` returned was used after its disposal.
class _ContactRenameDialog extends StatefulWidget {
  const _ContactRenameDialog(this.c);
  final ContactInfo c;

  @override
  State<_ContactRenameDialog> createState() => _ContactRenameDialogState();
}

class _ContactRenameDialogState extends State<_ContactRenameDialog> {
  late final _ctl = TextEditingController(text: widget.c.label);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => XDialogShell(
        title: context.l.cardRename,
        icon: Icons.edit_outlined,
        width: 440,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonCancel)),
          FilledButton(
            key: const Key('rename-ok'),
            onPressed: () => Navigator.pop(context, _ctl.text.trim()),
            child: Text(context.l.commonSave),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const Key('rename-field'),
            controller: _ctl,
            autofocus: true,
            style: XText.body,
            decoration: InputDecoration(labelText: context.l.cardContactName),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
          const SizedBox(height: 8),
          Text(context.l.cardRenameNote, style: XText.monoSmall),
        ]),
      );
}

class TrustSection extends StatefulWidget {
  const TrustSection(this.c, {super.key, this.editable = true});
  final ContactInfo c;
  final bool editable;

  @override
  State<TrustSection> createState() => _TrustSectionState();
}

class _TrustSectionState extends State<TrustSection> {
  late int _level = widget.c.trust;
  bool _editing = false;
  Object? _error;

  Future<void> _apply() async {
    final c = widget.c;
    final l = context.l;
    final m = AppScope.read(context);
    final level = _level;
    final (done, err) = await confirmOwner(
      context,
      action: l.trustChangeAction(c.label, trustGlyph(c.trust), trustGlyph(level)),
      detail: TrustLevel.defaultNetMode(level) != c.netMode
          ? l.cardNetModeChanges(netModeLabel(l, TrustLevel.defaultNetMode(level)).toLowerCase())
          : null,
      cli: 'antenna trust ${c.label} $level',
      run: (auth) => m.setTrust(c.linkId, level, auth),
    );
    if (!mounted || (!done && err == null)) return;
    setState(() {
      _error = err;
      if (err == null) _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final t = TrustLevel.of(c.trust);
    final color = XColors.trustColor(c.trust);
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(
        l.cardTrust,
        trailing: widget.editable && !_editing
            ? InkWell(
                key: const Key('trust-edit'),
                onTap: () => setState(() {
                  _editing = true;
                  _level = c.trust;
                }),
                child: Text(l.cardChange, style: XText.monoSmall.copyWith(color: XColors.accent)),
              )
            : null,
      ),
      Row(children: [
        TrustBadge(c.trust, size: 34),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${trustGlyph(t.level)} · ${c.trust == 5 ? l.trustSelfName : t.name(l)}',
                style: XText.title.copyWith(color: color)),
            const SizedBox(height: 2),
            Text(l.cardYourLevel, style: XText.monoSmall),
          ]),
        ),
        if (c.trust == 5) const SelfMark(size: 20),
      ]),
      // Level 5 is the owner's own computer: say what goes without asking.
      if (c.trust == 5) ...[
        const SizedBox(height: 8),
        Text(l.trustSelfMeaning, key: const Key('trust-self-meaning'), style: XText.bodyDim.copyWith(fontSize: 12)),
      ],
      const SizedBox(height: 8),
      if (_editing) ...[
        // Back to level 5 for a contact that is at 5 already changes nothing: no warning then.
        TrustPicker(
          value: _level,
          onChanged: (v) => setState(() => _level = v),
          confirmSelf: c.trust == 5 ? () async => true : null,
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => setState(() => _editing = false), child: Text(l.commonCancel)),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('trust-apply'),
            onPressed: _level == c.trust ? null : _apply,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
            child: Text(l.commonApply),
          ),
        ]),
        if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      ] else
        _LevelScale(c.trust),
      const SizedBox(height: 12),
      // Level rights come from the daemon (v2, `contacts[].rights`); for a v1 daemon, the SPEC §9 text.
      if (c.rights case final r?) ...[
        FactRow(l.cardRightsMessages, r.messages, valueColor: XColors.textDim),
        FactRow(l.cardRightsFiles, r.files, valueColor: XColors.textDim),
        FactRow(l.cardRightsTasks, r.tasks, valueColor: XColors.textDim),
        FactRow(l.cardRightsCommands, r.commands, valueColor: XColors.textDim),
        FactRow(l.cardRightsLimit, l.trustLimitMessages(r.msgsPerMin), valueColor: XColors.textDim),
      ] else ...[
        FactRow(l.cardRightsMessages, t.messages(l), valueColor: XColors.textDim),
        FactRow(l.cardRightsFiles, t.files(l), valueColor: XColors.textDim),
        FactRow(l.cardRightsTasks, t.tasks(l), valueColor: XColors.textDim),
        FactRow(l.cardRightsCommands, t.commands(l), valueColor: XColors.textDim),
        FactRow(l.cardRightsLimit, t.limit(l), valueColor: XColors.textDim),
      ],
      const SizedBox(height: 8),
      Text(l.cardRightsNote, style: XText.monoSmall),
    ]);
  }
}

class _LevelScale extends StatelessWidget {
  const _LevelScale(this.level);
  final int level;

  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 1; i <= 5; i++) ...[
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: i <= level ? XColors.trustColor(i) : XColors.line,
                boxShadow: i == level
                    ? [BoxShadow(color: XColors.trustColor(i).withValues(alpha: 0.6), blurRadius: 8)]
                    : null,
              ),
            ),
          ),
          if (i < 5) const SizedBox(width: 4),
        ],
      ]);
}

class NetSection extends StatelessWidget {
  const NetSection(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final presence = AppScope.maybeOf(context)?.presenceOf(c);
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.pairFactNetwork),
      Row(children: [
        Icon(c.netMode == 'relay_only' ? Icons.cell_tower_outlined : Icons.swap_horiz, size: 18, color: XColors.accent),
        const SizedBox(width: 8),
        Text(netModeLabel(l, c.netMode), style: XText.title),
      ]),
      const SizedBox(height: 4),
      Text(netModeHint(l, c.netMode), style: XText.bodyDim.copyWith(fontSize: 12)),
      const SizedBox(height: 8),
      FactRow(
        l.cardPresence,
        switch (presence) {
          true => l.commonOnline,
          false => l.commonOffline,
          null => l.cardPresenceNotTracked,
        },
        valueColor: presence == true ? XColors.ok : XColors.textDim,
      ),
      if (c.transport.lastPaths.isNotEmpty)
        FactRow(l.cardPath, c.transport.lastPaths.map((p) => p.replaceFirst('*', '')).join('\n'),
            tooltip: l.cardPathTooltip),
      FactRow(l.cardQueued, '${c.outbox}', valueColor: c.outbox > 0 ? XColors.warn : null),
      FactRow(l.cardNotDelivered, '${c.failed}', valueColor: c.failed > 0 ? XColors.danger : null),
    ]);
  }
}

class CryptoSection extends StatelessWidget {
  const CryptoSection(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final f = PqFacts(c);
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.cardEncryption, trailing: PqChip(c, dense: true)),
      for (final (k, v) in f.lines(l))
        FactRow(k, v, valueColor: v.contains(hybridGroup) || v.startsWith('v4') || v.startsWith('Negotiation') ? XColors.accent : null),
      const SizedBox(height: 8),
      Text(
        l.cardEncryptionNote,
        style: XText.monoSmall,
      ),
    ]);
  }
}

class LinkSection extends StatelessWidget {
  const LinkSection(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionLabel(context.l.cardLink),
        _Copyable(context.l.pairFactLinkId, c.linkId),
        _Copyable(context.l.cardYourEndpoint, c.localEndpoint, tip: context.l.cardYourEndpointTooltip),
        _Copyable(context.l.cardContactEndpoint, c.peerEndpoint),
        FactRow(context.l.cardHistoryHeads, c.heads.isEmpty ? '—' : c.heads.map((h) => shortHex(h, head: 8, tail: 4)).join('\n')),
        FactRow('Lamport', '${c.lamport}'),
      ]);
}

class _Copyable extends StatelessWidget {
  const _Copyable(this.k, this.v, {this.tip});
  final String k;
  final String v;
  final String? tip;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => Clipboard.setData(ClipboardData(text: v)),
        child: FactRow(k, shortHex(v, head: 8, tail: 6), tooltip: '${tip == null ? '' : '$tip\n'}$v\n${context.l.cardClickToCopy}'),
      );
}

/// Log of actions taken on the contact's requests (`antenna log`, the SPEC §9 audit log).
class AuditSection extends StatefulWidget {
  const AuditSection(this.c, {super.key, this.entries});
  final ContactInfo c;

  /// For mockups: entries are given explicitly, without asking the daemon.
  final List<ReceiptInfo>? entries;

  @override
  State<AuditSection> createState() => _AuditSectionState();
}

class _AuditSectionState extends State<AuditSection> {
  List<ReceiptInfo>? _entries;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _entries = widget.entries;
    if (_entries == null) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final m = AppScope.maybeOf(context);
    if (m == null) return;
    try {
      final e = await m.daemon.log(widget.c.linkId, limit: 8);
      if (mounted) setState(() => _entries = e);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = _entries;
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.cardActivityLog, trailing: Text('antenna log', style: XText.monoSmall)),
      Text(l.cardActivityLegend,
          style: XText.monoSmall.copyWith(fontSize: 11)),
      const SizedBox(height: 4),
      if (_error != null)
        Text(describeError(l, _error!), style: XText.monoSmall.copyWith(color: XColors.warn))
      else if (e == null)
        Text(l.commonLoading, style: XText.monoSmall)
      else if (e.isEmpty)
        Text(l.cardActivityEmpty, style: XText.bodyDim.copyWith(fontSize: 12))
      else
        for (final r in e.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(hhmm(DateTime.fromMillisecondsSinceEpoch(r.ts)), style: XText.monoSmall),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  if (r.source.isNotEmpty)
                    TextSpan(
                      text: r.source == 'dag' ? (r.author == 'contact' ? '← ' : '→ ') : '· ',
                      style: XText.mono.copyWith(color: r.source == 'dag' ? XColors.accent : XColors.textMute),
                    ),
                  TextSpan(text: '${r.actor} ', style: XText.mono.copyWith(color: XColors.text)),
                  TextSpan(text: '${r.action} ', style: XText.mono),
                  TextSpan(text: r.decision, style: XText.mono.copyWith(color: _decisionColor(r.decision))),
                  if (r.reason.isNotEmpty) TextSpan(text: '  ${r.reason}', style: XText.monoSmall),
                ])),
              ),
            ]),
          ),
    ]);
  }

  Color _decisionColor(String d) => switch (d) {
        'allowed' || 'approved' => XColors.ok,
        'denied' || 'rate_limited' => XColors.danger,
        _ => XColors.warn,
      };
}

/// History verification (SPEC §8, v2): state, fingerprint, counters, "Verify now".
class HistorySection extends StatelessWidget {
  const HistorySection(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final h = c.history;
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(
        l.cardHistory,
        trailing: InkWell(
          key: const Key('history-verify'),
          onTap: () => AppScope.read(context).verify(c.linkId),
          child: Text(l.cardVerifyNow, style: XText.monoSmall.copyWith(color: XColors.accent)),
        ),
      ),
      if (h == null)
        Text(l.cardHistoryUnsupported, style: XText.bodyDim.copyWith(fontSize: 12))
      else ...[
        FactRow(
          l.daemonFactState,
          switch (h.state) {
            'verified' => l.cardHistoryVerified,
            'syncing' => l.cardHistorySyncing,
            'mismatch' => h.sendBlocked ? l.cardHistoryMismatchReadOnly : l.historyMismatch,
            'rolled_back' => l.cardHistoryRolledBack,
            'peer_rolled_back' => l.historyPeerRolledBack,
            _ => l.cardHistoryUnchecked,
          },
          valueColor: switch (h.state) {
            'verified' => XColors.ok,
            'mismatch' || 'rolled_back' => XColors.danger,
            'peer_rolled_back' => XColors.warn,
            _ => XColors.textDim,
          },
        ),
        if (h.fingerprintDigits != null)
          FactRow(
            l.cardFingerprint,
            '${digitGlyphs(h.fingerprintDigits!)?.map((g) => g.name(l)).join(' · ') ?? ''}  (${h.fingerprintDigits})',
            tooltip: l.cardFingerprintTooltip,
          ),
        if (h.atMs != null) FactRow(l.cardVerifiedAt, formatDateTime(l, DateTime.fromMillisecondsSinceEpoch(h.atMs!))),
        FactRow(l.cardMessagesInRow,
            l.cardMessagesInRowValue(h.counts.isNotEmpty ? h.counts[0] : 0, h.counts.length > 1 ? h.counts[1] : 0)),
      ],
    ]);
  }
}

/// Delete the link (`revoke`, SPEC §5): the link keys are wiped and the channel is closed; history is kept or deleted
/// by choice. Needs the password.
class RevokeSection extends StatelessWidget {
  const RevokeSection(this.c, {super.key});
  final ContactInfo c;

  Future<void> _revoke(BuildContext context) async {
    final m = AppScope.read(context);
    final pw = OwnerAuthController();
    var deleteHistory = false;
    final ok = await showXDialog<bool>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, set) => XDialogShell(
          title: ctx.l.cardRevokeTitle(c.label),
          icon: Icons.link_off,
          width: 480,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l.commonCancel)),
            FilledButton(
              key: const Key('revoke-ok'),
              style: XButtons.destructiveFilled(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.l.cardRevoke),
            ),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              ctx.l.cardRevokeBody,
              style: XText.bodyDim,
            ),
            const SizedBox(height: 8),
            // Its own Material: the dialog panel's background would hide the tile's ink (a debug assertion).
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                key: const Key('revoke-history'),
                value: deleteHistory,
                onChanged: (v) => set(() => deleteHistory = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(ctx.l.cardRevokeHistory, style: XText.body),
              ),
            ),
            const SizedBox(height: 8),
            OwnerAuthField(controller: pw),
          ]),
        ),
      ),
    );
    final touch = pw.usesTouch(m);
    final password = pw.password.text;
    pw.dispose();
    if (ok != true || !context.mounted) return;
    final l = context.l;
    // One touch now, after the owner's click on Remove; when it does not go through, the password prompt (D-131).
    final (_, err) = touch
        ? await confirmOwner(context,
            action: l.cardRevokeTitle(c.label),
            detail: deleteHistory ? l.cardRevokeHistory : null,
            cli: 'antenna revoke ${c.label}${deleteHistory ? ' --delete-history' : ''}',
            run: (auth) => m.revoke(c.linkId, auth, deleteHistory: deleteHistory))
        : (false, await m.revoke(c.linkId, PasswordAuth(password), deleteHistory: deleteHistory));
    if (err != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
    }
  }

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('contact-revoke'),
          onPressed: () => _revoke(context),
          style: XButtons.destructive(),
          icon: const Icon(Icons.link_off, size: 16),
          label: Text(context.l.cardRevokeButton),
        ),
      );
}

/// The contact's agents in this link (v5, CONTROL §17): who writes on the contact's behalf. The names are contact data.
class ContactAgentsSection extends StatelessWidget {
  const ContactAgentsSection(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(l.cardAgentsTitle),
      if (c.agents.isEmpty)
        Text(
          c.peerKind == 'human' ? l.cardAgentsNoneHuman : l.cardAgentsUnknown,
          style: XText.bodyDim,
        )
      else
        for (final a in c.agents)
          Padding(
            key: Key('peer-agent-${a.name}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                AgentAvatar(AgentRef(a.name, contact: c.label, linkId: c.linkId), size: 28),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.viaContactAgent(c.label, a.name),
                    style: XText.body.copyWith(
                      decoration: a.state == 'revoked' ? TextDecoration.lineThrough : null,
                      color: a.state == 'revoked' ? XColors.textMute : XColors.text,
                    ),
                  ),
                ),
                Text(
                  a.state == 'revoked'
                      ? l.cardAgentRevoked
                      : l.cardAgentSince(formatDate(l, DateTime.fromMillisecondsSinceEpoch(a.sinceMs))),
                  style: XText.meta,
                ),
                _PeerAgentPictureMenu(c.linkId, a.name),
              ]),
              _PictureWithheldNote(c.linkId, a.name),
            ]),
          ),
      const SizedBox(height: 4),
      Text(l.cardAgentsNote, style: XText.meta),
    ]);
  }
}

/// "Set picture…" / "Reset to theirs" for a contact's agent (D-UI-43): a local override, this computer only.
class _PeerAgentPictureMenu extends StatelessWidget {
  const _PeerAgentPictureMenu(this.linkId, this.agent);
  final String linkId;
  final String agent;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.maybeOf(context);
    final l = context.l;
    final hasOverride = m?.chatPictureOverride(linkId, agent) != null;
    return PopupMenuButton<VoidCallback>(
      key: Key('peer-agent-picture-menu-$agent'),
      tooltip: l.chatMenuSetPicture,
      icon: Icon(Icons.add_a_photo_outlined, size: 16, color: XColors.textDim),
      itemBuilder: (ctx) => [
        PopupMenuItem(
          key: const Key('peer-agent-picture-set'),
          value: () => showChatPicturePicker(context, linkId: linkId, agent: agent),
          child: Text(l.chatMenuSetPicture),
        ),
        if (hasOverride)
          PopupMenuItem(
            key: const Key('peer-agent-picture-reset'),
            value: () => AppScope.read(context).removeChatPictureOverride(linkId, agent),
            child: Text(l.chatPictureReset),
          ),
      ],
      onSelected: (action) => action(),
    );
  }
}

/// Why this agent's picture is not shown, when the contact announced one and it did not pass (field feedback
/// 2026-10-06, a check failure looked exactly like "no picture"): nothing when there is nothing to say.
class _PictureWithheldNote extends StatelessWidget {
  const _PictureWithheldNote(this.linkId, this.agent);
  final String linkId;
  final String agent;

  @override
  Widget build(BuildContext context) {
    final withheld = AppScope.maybeOf(context)?.pictureWithheldOf(linkId, agent: agent);
    final l = context.l;
    final text = switch (withheld) {
      PictureWithheld.level => l.pictureWithheldLevel,
      PictureWithheld.refused => l.pictureWithheldRefused,
      PictureWithheld.unavailable => l.pictureWithheldUnavailable,
      _ => null,
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 36, top: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.info_outline, size: 13, color: XColors.warn),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: XText.meta.copyWith(color: XColors.warn))),
      ]),
    );
  }
}

