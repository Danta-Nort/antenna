// SPDX-License-Identifier: AGPL-3.0-only
// My devices (PG-10, PG-25, PG-14, D-106; experimental): this computer and the owner's other computers (the contacts at
// ∞) in one place. Each own computer tells the others about itself over their link (PROTOCOL §24): its system, its
// Antenna and updates, health, agents, the requests waiting for the owner. A request is answered from here; the
// computer that asked checks the proof itself. A lost computer is revoked from here. "Lend this computer to my teams"
// is this computer's own switch.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/section_page.dart';
import 'device_card.dart';
import 'device_text.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).refreshDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final r = m.devices;
    return SectionPage(
      title: l.navDevices,
      subtitle: l.devicesSubtitle,
      action: const Padding(padding: EdgeInsets.only(top: 8), child: ExperimentalTag()),
      children: [
        if (!m.devicesSupported)
          SectionCard(child: Text(l.devicesAbsent, style: XText.bodyDim))
        else if (r == null)
          SectionCard(
            child: m.devicesError == null
                ? Text(l.commonLoading, style: XText.bodyDim)
                : ErrorLine(describeError(l, m.devicesError!), detail: errorDetail(m.devicesError!)),
          )
        else ...[
          _ThisComputer(r.self),
          if (r.devices.isEmpty)
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.devicesEmptyTitle, style: XText.title),
                const SizedBox(height: 8),
                Text(l.devicesEmptyBody, style: XText.bodyDim),
              ]),
            )
          else
            for (final d in r.devices) DeviceCard(d, key: ValueKey(d.linkId), initiallyOpen: r.devices.length == 1),
        ],
      ],
    );
  }
}

/// This computer: what the others see of it, the keys it answers their requests with, the computers revoked here as
/// lost, and "Lend this computer to my teams".
class _ThisComputer extends StatefulWidget {
  const _ThisComputer(this.self);
  final ThisDevice self;

  @override
  State<_ThisComputer> createState() => _ThisComputerState();
}

class _ThisComputerState extends State<_ThisComputer> {
  bool _busy = false;
  Object? _error;

  Future<void> _lend(bool on) async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() {
      _busy = true;
      _error = null;
    });
    final Object? err;
    if (on) {
      (_, err) = await confirmOwner(context,
          action: l.devicesLendAction,
          detail: l.devicesLendHelp,
          cli: 'antenna devices lend on',
          run: (auth) => m.setLend(true, auth: auth));
    } else {
      err = await m.setLend(false);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final s = widget.self;
    final now = AppScope.of(context).now();
    return SectionCard(
      child: Column(key: const Key('this-computer'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
            child: Icon(s.os == 'linux' ? Icons.dns_outlined : Icons.laptop_mac_outlined, size: 20, color: XColors.accent),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.devicesThisComputer, style: XText.title),
              const SizedBox(height: 2),
              Text(
                [
                  if (s.name.isNotEmpty) s.name,
                  deviceSystem(s.os, s.osVersion, s.arch),
                  'Antenna ${deviceVersion(s.version)}',
                ].join(' · '),
                style: XText.meta,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.devicesLend, style: XText.body.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(l.devicesLendHelp, style: XText.meta),
            ]),
          ),
          const SizedBox(width: 16),
          Switch(key: const Key('device-lend'), value: s.lend, onChanged: _busy ? null : _lend),
        ]),
        const SizedBox(height: 12),
        Text(
          s.keys.isEmpty ? l.devicesThisKeysNone : l.devicesThisKeys(deviceKeys(l, s.keys, here: true)),
          style: XText.bodyDim,
        ),
        for (final x in s.lost)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Icon(Icons.phonelink_erase_outlined, size: 16, color: XColors.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.devicesRevokedLost(x.contact, shortStamp(l, DateTime.fromMillisecondsSinceEpoch(x.atMs), now)),
                  style: XText.bodyDim,
                ),
              ),
            ]),
          ),
        if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      ]),
    );
  }
}
