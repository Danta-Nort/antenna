// SPDX-License-Identifier: AGPL-3.0-only
// One of the owner's other computers (a contact at ∞) in My devices: what it last told this one (system, Antenna and
// its updates, health, agents, the requests waiting for the owner), which of its keys answer approvals here, and
// "Revoke this computer" for a lost one. A card folds to its header; it opens by itself when something waits.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../state/pictures.dart';
import '../../theme/x_theme.dart';
import '../agents/agent_stop_dialog.dart';
import '../agents/approver_dialog.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/profile_picture.dart';
import '../widgets/x_buttons.dart';
import 'device_dialogs.dart';
import 'device_request.dart';
import 'device_text.dart';

class DeviceCard extends StatefulWidget {
  const DeviceCard(this.d, {super.key, this.initiallyOpen = false});
  final DeviceInfo d;
  final bool initiallyOpen;

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  late bool _open = widget.initiallyOpen || _needsLook(widget.d);
  bool _busy = false;
  Object? _error;

  static bool _needsLook(DeviceInfo d) =>
      d.pending > 0 || d.lostBy != null || (d.status?.health.any((h) => h.problem) ?? false) || d.offered.isNotEmpty;

  @override
  void didUpdateWidget(DeviceCard old) {
    super.didUpdateWidget(old);
    if (!_open && _needsLook(widget.d) && !_needsLook(old.d)) _open = true;
  }

  Future<void> _do(Future<Object?> Function() op) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await op();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _confirm() async {
    final d = widget.d;
    final l = context.l;
    final m = AppScope.read(context);
    final keys = [for (final k in d.offered) k.keyId];
    await _do(() async => (await confirmOwner(
          context,
          action: l.devicesConfirmAction(d.contact, deviceKeys(l, d.offered)),
          detail: l.devicesConfirmDetail(d.contact),
          cli: 'antenna devices confirm ${d.contact}',
          run: (auth) => m.deviceConfirmKeys(d, keys, auth),
        ))
            .$2);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final d = widget.d;
    final s = d.status;
    final now = m.now();
    final heard = d.receivedMs == null ? null : shortStamp(l, DateTime.fromMillisecondsSinceEpoch(d.receivedMs!), now);
    return Container(
      key: Key('device-${d.contact}'),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, glow: 0.6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          key: Key('device-toggle-${d.contact}'),
          borderRadius: BorderRadius.circular(XRadius.l),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
            child: Row(children: [
              // The computer's picture is the one its owner (the same person) chose there (CONTROL §28)
              _ComputerIcon(os: s?.os, online: d.online, picture: m.pictureOfContact(d.linkId), label: d.contact),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(d.contact, style: XText.title, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    const TrustBadge(5, size: 18),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    [
                      d.online ? l.devicesOnline : l.devicesOffline,
                      if (s != null) deviceSystem(s.os, s.osVersion, s.arch),
                      if (s != null) 'Antenna ${deviceVersion(s.version)}',
                      if (!d.online && heard != null) l.devicesLastHeard(heard),
                    ].join(' · '),
                    style: XText.meta,
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              ),
              if (d.lostBy != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.report_outlined, size: 18, color: XColors.danger),
              ],
              if (s?.health.any((h) => h.problem) ?? false) ...[
                const SizedBox(width: 8),
                Icon(Icons.warning_amber_rounded, size: 18, color: XColors.warn),
              ],
              if (d.pending > 0) ...[const SizedBox(width: 8), CountBubble(d.pending)],
              const SizedBox(width: 8),
              Icon(_open ? Icons.expand_less : Icons.expand_more, size: 20, color: XColors.textDim),
            ]),
          ),
        ),
        if (_open) ...[
          Divider(height: 1, color: XColors.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (d.lostBy case final r?) _LostBanner(d, r, onDismiss: _busy ? null : () => _do(() => m.deviceDismissLost(d))),
              if (s == null)
                Text(d.supported ? l.devicesNotHeardYet : l.devicesUnsupported, style: XText.bodyDim)
              else
                ..._facts(context, d, s, now),
              const SizedBox(height: 16),
              _Keys(d, busy: _busy, onConfirm: _confirm, onForget: () => _do(() => m.deviceForgetKeys(d))),
              if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('device-revoke-${d.contact}'),
                  style: XButtons.destructive(),
                  onPressed: _busy ? null : () => showRevokeDeviceDialog(context, d),
                  icon: const Icon(Icons.phonelink_erase_outlined, size: 17),
                  label: Text(l.devicesRevoke),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  List<Widget> _facts(BuildContext context, DeviceInfo d, DeviceView s, DateTime now) {
    final l = context.l;
    final shown = s.approvals.length;
    return [
      // What waits for the owner first: it is why the card opened
      SectionLabel(l.devicesRequests(s.pendingApprovals)),
      if (s.approvals.isEmpty)
        Text(d.online ? l.devicesRequestsNone : l.devicesRequestsOffline, style: XText.bodyDim)
      else ...[
        for (final a in s.approvals) DeviceRequestCard(d, a, key: ValueKey('${d.linkId}-${a.id}')),
        if (s.pendingApprovals > shown) ...[
          const SizedBox(height: 8),
          Text(l.devicesRequestsMore(s.pendingApprovals - shown, d.contact), style: XText.meta),
        ],
      ],
      const SizedBox(height: 16),
      SectionLabel(l.devicesAbout),
      FactRow(l.devicesFactName, s.name.isEmpty ? '—' : s.name),
      FactRow(l.devicesFactSystem, deviceSystem(s.os, s.osVersion, s.arch)),
      FactRow(l.devicesFactMemory, deviceMemory(s.memoryBytes)),
      FactRow('Antenna', deviceVersion(s.version)),
      FactRow(l.devicesFactUpdates, deviceUpdateLine(l, s.update, now)),
      if (s.lend) FactRow(l.devicesFactTeams, l.devicesLends),
      const SizedBox(height: 16),
      SectionLabel(l.devicesHealth),
      if (s.health.isEmpty)
        Text(l.devicesHealthOk, style: XText.bodyDim)
      else
        for (final h in s.health)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Icon(h.problem ? Icons.error_outline : Icons.info_outline,
                  size: 16, color: h.problem ? XColors.warn : XColors.textDim),
              const SizedBox(width: 8),
              Expanded(child: Text(deviceHealthLine(l, h), style: XText.body)),
            ]),
          ),
      const SizedBox(height: 16),
      SectionLabel(l.devicesAgents),
      if (s.agents.isEmpty)
        Text(l.devicesAgentsNone, style: XText.bodyDim)
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in s.agents)
            Container(
              key: Key('device-agent-${d.contact}-${a.name}'),
              padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
              decoration: BoxDecoration(
                color: XColors.bg2,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: XColors.line),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                XAvatar(a.name,
                    size: 22,
                    agent: true,
                    picture: AppScope.of(context).pictureOfContact(d.linkId, agent: a.name)),
                const SizedBox(width: 8),
                Text(a.name, style: XText.label.copyWith(color: XColors.text)),
                const SizedBox(width: 8),
                Text(
                  [
                    if (a.app != null && a.app != a.name && a.app != 'local') a.app!,
                    deviceAgentState(l, a),
                  ].join(' · '),
                  style: XText.meta,
                ),
                // That computer's agent can answer this computer's requests (CONTROL §31; experimental)
                if (AppScope.of(context).approversKnown && a.app != 'local')
                  _ApproverChipButton(device: d.contact, agent: a.name),
                // The stop switch over the link (CONTROL §33; experimental): only where that computer can do it
                _StopChipButton(device: d, agent: a.name),
              ]),
            ),
        ]),
    ];
  }
}

/// A computer drawn as its profile picture when it has one, else as its system: a laptop for macOS, a server rack for
/// Linux; a dot for online.
class _ComputerIcon extends StatelessWidget {
  const _ComputerIcon({required this.os, required this.online, required this.label, this.picture});
  final String? os;
  final bool online;
  final String label;
  final ShownPicture? picture;

  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, children: [
        if (picture case final p?)
          PictureFace(p, size: 40, label: label)
        else
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
            child:
                Icon(os == 'linux' ? Icons.dns_outlined : Icons.laptop_mac_outlined, size: 20, color: XColors.accent),
          ),
        Positioned(right: -1, bottom: -1, child: PresenceDot(online: online, size: 11)),
      ]);
}

/// Another own computer reported this one as lost: its keys no longer approve here; revoke it here too, or say it is
/// not lost.
class _LostBanner extends StatelessWidget {
  const _LostBanner(this.d, this.r, {required this.onDismiss});
  final DeviceInfo d;
  final LostReport r;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final now = AppScope.of(context).now();
    return Container(
      key: Key('device-lost-${d.contact}'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: xPanel(
        fill: Color.alphaBlend(XColors.danger.withValues(alpha: 0.07), XColors.bg1),
        border: XColors.danger.withValues(alpha: 0.4),
        radius: XRadius.m,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.report_outlined, size: 18, color: XColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.devicesLostBanner(r.contact, shortStamp(l, DateTime.fromMillisecondsSinceEpoch(r.atMs), now)),
              style: XText.body,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
          TextButton(
            key: Key('device-lost-dismiss-${d.contact}'),
            style: XButtons.tertiary(),
            onPressed: onDismiss,
            child: Text(l.devicesLostDismiss),
          ),
          FilledButton(
            key: Key('device-lost-revoke-${d.contact}'),
            style: XButtons.destructiveFilled(),
            onPressed: () => showRevokeDeviceDialog(context, d),
            child: Text(l.devicesRevoke),
          ),
        ]),
      ]),
    );
  }
}

/// Which keys of that computer answer approvals here, the ones it offers, and which of this computer's it accepts.
class _Keys extends StatelessWidget {
  const _Keys(this.d, {required this.busy, required this.onConfirm, required this.onForget});
  final DeviceInfo d;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final mine = m.devices?.self.keys.where((k) => d.acceptsMine.contains(k.keyId)).toList() ?? const [];
    return Column(key: Key('device-keys-${d.contact}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(l.devicesApprovals),
      Text(
        d.confirmed.isEmpty ? l.devicesAcceptsNone(d.contact) : l.devicesAccepts(d.contact, deviceKeys(l, d.confirmed)),
        style: XText.body,
      ),
      const SizedBox(height: 4),
      Text(
        mine.isEmpty ? l.devicesMineNone(d.contact) : l.devicesMine(d.contact, deviceKeys(l, mine, here: true)),
        style: XText.bodyDim,
      ),
      // Approver agents (CONTROL §31): which of this computer's agents that computer lets answer its requests
      if (d.status?.approvers case final ap? when ap.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          l.devicesAcceptsApprovers(
              d.contact, [for (final x in ap) '${x.agent} (${approverScope(l, x.agents, x.kinds)})'].join(', ')),
          key: Key('device-approvers-${d.contact}'),
          style: XText.bodyDim.copyWith(color: XColors.accent),
        ),
      ],
      if (d.offered.isNotEmpty || d.confirmed.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
          if (d.confirmed.isNotEmpty)
            TextButton(
              key: Key('device-forget-${d.contact}'),
              style: XButtons.tertiary(),
              onPressed: busy ? null : onForget,
              child: Text(l.devicesForget),
            ),
          if (d.offered.isNotEmpty)
            Tooltip(
              message: d.offered.map((k) => '${deviceKeyKind(l, k)}: ${k.label} (${k.keyId})').join('\n'),
              child: FilledButton(
                key: Key('device-confirm-${d.contact}'),
                style: XButtons.primary(),
                onPressed: busy ? null : onConfirm,
                child: Text(l.devicesConfirm(deviceKeys(l, d.offered))),
              ),
            ),
        ]),
      ],
    ]);
  }
}

/// "Stop agent and its processes…" on an own computer's agent: that computer stops it (`stop_agents`); off, and says
/// why, when its Antenna is older.
class _StopChipButton extends StatelessWidget {
  const _StopChipButton({required this.device, required this.agent});
  final DeviceInfo device;
  final String agent;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final can = device.stopAgents;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: can
            ? '${l.agentStopAction} · ${l.experimentalTag}'
            : '${l.agentStopAction}\n${l.agentStopOlderDevice(device.contact)}',
        child: InkWell(
          key: Key('device-agent-stop-${device.contact}-$agent'),
          borderRadius: BorderRadius.circular(XRadius.m),
          onTap: can ? () => stopAgentWithConfirm(context, agent, computer: device.contact) : null,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(Icons.stop_circle_outlined, size: 16, color: can ? XColors.danger : XColors.textMute),
          ),
        ),
      ),
    );
  }
}

/// "Can approve for…" on an own computer's agent: opens the approver dialog for it.
class _ApproverChipButton extends StatelessWidget {
  const _ApproverChipButton({required this.device, required this.agent});
  final String device;
  final String agent;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final on = m.approverOf(agent, contact: device) != null;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: '${l.approverAction} · ${l.experimentalTag}',
        child: InkWell(
          key: Key('device-agent-approver-$device-$agent'),
          borderRadius: BorderRadius.circular(XRadius.m),
          onTap: () => showApproverDialog(context, agent: agent, contact: device),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(on ? Icons.how_to_reg : Icons.how_to_reg_outlined,
                size: 16, color: on ? XColors.accent : XColors.textDim),
          ),
        ),
      ),
    );
  }
}
