// SPDX-License-Identifier: AGPL-3.0-only
// Connecting and disconnecting agents (CONTROL §30, D-123; experimental): the dialog says exactly what will be set,
// on this computer and on the other one, before anything is sent. On this computer: where the agent's messages without
// an address go (fixed by the line) and whether the other end's messages are tasks for it (D-88). On another own
// computer: the same for its agent, which that computer turns into an approval request for the owner (there, or here
// in My devices). A contact's side is that contact's decision: nothing is sent for it. Connecting takes the owner
// password, never kept; disconnecting only takes away (D-84) and takes none.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/agent_map.dart';
import '../../state/messages.dart';
import '../../state/owner_auth.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../devices/device_request.dart';
import '../security/owner_confirm.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/agent_logo.dart' show AgentRef;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/x_buttons.dart';
import 'agent_map_text.dart';

/// A word of the shell command line: quoted when it has a space.
String shellArg(String s) => s.contains(RegExp(r'''[\s'"]''')) ? "'${s.replaceAll("'", r"'\''")}'" : s;

Widget busyLabel(bool busy, String text) =>
    busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(text);

/// Where a dialog leaves its last outcome, however it is closed (a button, Escape, a click outside).
final class OutcomeBox {
  ConnectOutcome? outcome;
}

/// The two ends of a line, side by side: picture, name, where it is.
class MapConnectEnds extends StatelessWidget {
  const MapConnectEnds(this.a, this.b,
      {super.key, required this.aWhere, required this.bWhere, required this.aKind, required this.bKind});
  final MapNode a;
  final MapNode b;
  final String aWhere;
  final String bWhere;
  final String aKind;
  final String bKind;

  Widget _end(BuildContext context, MapNode n, String where, String kind) {
    final picture = switch (n.kind) {
      MapNodeKind.local => AgentAvatar(AgentRef(n.name, mine: true), size: 36),
      MapNodeKind.person => XAvatar(n.name, size: 36, picture: AppScope.of(context).pictureOfContactLabel(n.name)),
      MapNodeKind.you => XAvatar(n.name, size: 36, picture: AppScope.of(context).pictureOfMine()),
      _ => AgentAvatar(AgentRef(n.name, contact: n.contact), size: 36),
    };
    return Expanded(
      child: Row(children: [
        picture,
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(mapNodeName(context.l, n), style: XText.title),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text('$where · $kind', style: XText.meta),
            ),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: xPanel(fill: XColors.bg2, border: XColors.line, radius: XRadius.l),
        child: Row(children: [
          _end(context, a, aWhere, aKind),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Icon(Icons.swap_horiz_rounded, size: 20, color: XColors.accent),
          ),
          _end(context, b, bWhere, bKind),
        ]),
      );
}

/// A checkbox with its label (and a hint under it).
class MapCheck extends StatelessWidget {
  const MapCheck({super.key, required this.k, required this.value, required this.label, this.hint, this.onChanged});
  final Key k;
  final bool value;
  final String label;
  final String? hint;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(XRadius.m),
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(key: k, value: value, onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(label, style: XText.body.copyWith(color: onChanged == null ? XColors.textMute : XColors.text)),
                ),
                if (hint != null) Text(hint!, style: XText.meta),
              ]),
            ),
          ]),
        ),
      );
}

/// A fact line of what will be set (fixed, not a choice).
class MapFact extends StatelessWidget {
  const MapFact(this.text, {super.key, this.icon = Icons.arrow_forward_rounded});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 24, child: Icon(icon, size: 16, color: XColors.accent)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: XText.body)),
        ]),
      );
}

/// What became of the request, in lines: this side, then the other side with its action.
class ConnectResultLines extends StatelessWidget {
  const ConnectResultLines({
    super.key,
    required this.outcome,
    required this.computer,
    required this.disconnect,
    this.onApproveNow,
    this.onAskAgain,
  });
  final ConnectOutcome outcome;

  /// The other end's computer: an own computer's or a contact's label.
  final String computer;
  final bool disconnect;
  final VoidCallback? onApproveNow;
  final VoidCallback? onAskAgain;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final r = outcome.reply;
    if (r == null) {
      final e = outcome.error ?? const XProtocolException('no reply');
      return ErrorLine(describeError(l, e), detail: errorDetail(e));
    }
    final s = r.otherSide;
    Widget line(IconData icon, Color color, String text, {Key? key}) => Padding(
          key: key,
          padding: const EdgeInsets.only(top: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: XText.body)),
          ]),
        );
    final other = switch (s.state) {
      OtherSideState.requested => line(Icons.hourglass_top_rounded, XColors.warn, l.mapConnectRequested(computer),
          key: const Key('agent-connect-requested')),
      OtherSideState.unchanged => line(Icons.check_rounded, XColors.ok, l.mapConnectUnchanged(computer)),
      OtherSideState.contactDecides => line(Icons.person_outline, XColors.textDim, l.mapConnectContactDecides(computer)),
      OtherSideState.person => line(Icons.person_outline, XColors.textDim, l.mapConnectPersonSide(computer)),
      OtherSideState.notAsked => line(Icons.info_outline, XColors.textDim, l.mapConnectNotAsked(computer)),
      OtherSideState.unsupported => line(Icons.system_update_alt_rounded, XColors.warn, l.mapConnectUnsupported(computer),
          key: const Key('agent-connect-unsupported')),
      OtherSideState.unreachable => line(Icons.cloud_off_rounded, XColors.warn, l.mapConnectUnreachable(computer),
          key: const Key('agent-connect-unreachable')),
      OtherSideState.refused => line(Icons.block_rounded, XColors.danger,
          l.mapConnectRefused(computer, [s.message, s.code].whereType<String>().join(' · ')),
          key: const Key('agent-connect-refused')),
      // Both sides of a local connection are on this computer: the first line says it all.
      OtherSideState.local => const SizedBox.shrink(),
      final x => line(Icons.info_outline, XColors.textDim, l.mapConnectOtherState(x)),
    };
    return Column(key: const Key('agent-connect-result'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      line(Icons.check_circle_rounded, XColors.ok, disconnect ? l.mapDisconnectDone : l.mapConnectDoneHere),
      other,
      if (s.state == OtherSideState.requested && onApproveNow != null)
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton(
              key: const Key('agent-connect-approve-now'),
              style: XButtons.primary(),
              onPressed: onApproveNow,
              child: Text(l.mapConnectApproveNow),
            ),
          ),
        ),
      if (s.state == OtherSideState.unreachable && onAskAgain != null)
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              key: const Key('agent-connect-ask-again'),
              style: XButtons.secondary(),
              onPressed: onAskAgain,
              child: Text(l.mapConnectAskAgain),
            ),
          ),
        ),
    ]);
  }
}

/// The connect dialog for a line from [local] (an agent of this computer) to [other]; its last outcome, if anything
/// was sent.
Future<ConnectOutcome?> showAgentConnectDialog(BuildContext context,
    {required AgentMapGraph graph, required MapNode local, required MapNode other}) async {
  final box = OutcomeBox();
  await showXDialog<void>(context, (_) => _ConnectDialog(graph: graph, local: local, other: other, box: box));
  return box.outcome;
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.graph, required this.local, required this.other, required this.box});
  final AgentMapGraph graph;
  final MapNode local;
  final MapNode other;
  final OutcomeBox box;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final _auth = OwnerAuthController();
  late final bool _own = widget.graph.own(widget.other);
  late final bool _currentTasks;
  late bool _tasks;
  bool _peerTasks = true;
  bool _busy = false;
  ConnectOutcome? _done;
  AgentConnectRequest? _sent;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final a = AppScope.read(context).agents.where((a) => a.name == widget.local.name).firstOrNull;
    _currentTasks = a?.tasksFrom?.contains(widget.other.contact) ?? false;
    // Tasks are for the owner's own computers and for those already trusted with tasks; a contact starts as data.
    _tasks = _currentTasks || _own;
  }

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  /// Sends [r] with [auth]; returns the refusal of the command itself, or `null`.
  Future<Object?> _send(AgentConnectRequest r, OwnerAuth auth) async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() => _busy = true);
    final out = await m.connectAgent(r, auth: auth);
    widget.box.outcome = out;
    _auth.password.clear();
    if (!mounted) return out.error;
    final fellBack = out.reply == null && _auth.fellBack(l, m, out.error);
    setState(() {
      _busy = false;
      _sent = r;
      // A refusal of the command itself keeps the form, so the owner can fix the password and try again.
      _done = out.reply == null ? null : out;
      _error = out.reply == null && !fellBack ? out.error : null;
    });
    return out.reply == null ? out.error : null;
  }

  void _connect() {
    final m = AppScope.read(context);
    final l = context.l;
    unawaited(_send(
        connectRequestFor(
          local: widget.local,
          other: widget.other,
          own: _own,
          tasks: _tasks,
          currentTasks: _currentTasks,
          peerTasks: _peerTasks,
          password: '',
        ),
        _auth.auth(m, touchIdConfirmReason(l, l.mapConnectAskAgainAction(widget.other.contact ?? '', widget.local.name)))));
  }

  Future<void> _askAgain() async {
    final l = context.l;
    final sent = _sent;
    if (sent == null) return;
    await confirmOwner(context,
        action: l.mapConnectAskAgainAction(widget.other.contact ?? '', widget.local.name),
        cli: _cli(sent),
        run: (auth) => _send(sent, auth));
  }

  String _cli(AgentConnectRequest r) => [
        'antenna agent connect',
        shellArg(r.name),
        shellArg(r.contact),
        if (r.agent != null) '--agent ${shellArg(r.agent!)}',
        if (r.tasks == true) '--tasks',
        if (r.tasks == false) '--no-tasks',
        if (r.peerTasks == true) '--peer-tasks',
        if (r.peerTasks == false) '--no-peer-tasks',
      ].join(' ');

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final a = widget.local;
    final b = widget.other;
    final computer = b.contact ?? '';
    final done = _done;
    final preview = connectRequestFor(
        local: a, other: b, own: _own, tasks: _tasks, currentTasks: _currentTasks, peerTasks: _peerTasks, password: '');
    return XDialogShell(
      key: const Key('agent-connect-dialog'),
      title: l.mapConnectTitle(a.name, mapEndName(l, b)),
      icon: Icons.hub_outlined,
      titleTag: const ExperimentalTag(),
      width: 640,
      actions: done != null
          ? [
              // Approve now or Ask again is the one primary action while there is one.
              if (const {OtherSideState.requested, OtherSideState.unreachable}.contains(done.reply?.otherSide.state))
                OutlinedButton(
                  key: const Key('agent-connect-close'),
                  style: XButtons.secondary(),
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.commonDone),
                )
              else
                FilledButton(
                  key: const Key('agent-connect-close'),
                  style: XButtons.primary(),
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.commonDone),
                ),
            ]
          : [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
              FilledButton(
                key: const Key('agent-connect-ok'),
                style: XButtons.primary(),
                onPressed: _busy ? null : _connect,
                child: busyLabel(_busy, l.mapConnectAction),
              ),
            ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MapConnectEnds(a, b,
            aWhere: l.devicesThisComputer,
            bWhere: computer,
            aKind: mapNodeKind(l, m, AppearanceScope.maybeOf(context), a),
            bKind: mapNodeKind(l, m, AppearanceScope.maybeOf(context), b)),
        const SizedBox(height: 16),
        SectionLabel(l.mapConnectHere),
        MapFact(b.person ? l.mapConnectHerePerson(a.name, b.name) : l.mapConnectHereLine(a.name, b.name, computer)),
        MapCheck(
          k: const Key('agent-connect-tasks'),
          value: _tasks,
          label: l.mapConnectTasks(computer, a.name),
          hint: _own ? null : l.mapConnectTasksHint(a.name, computer),
          onChanged: done != null || _busy ? null : (v) => setState(() => _tasks = v),
        ),
        if (_own && !b.person) ...[
          const SizedBox(height: 16),
          SectionLabel(l.mapConnectOn(computer)),
          MapFact(l.mapConnectPeerLine(b.name, a.name)),
          MapCheck(
            k: const Key('agent-connect-peer-tasks'),
            value: _peerTasks,
            label: l.mapConnectPeerTasks(b.name),
            onChanged: done != null || _busy ? null : (v) => setState(() => _peerTasks = v),
          ),
          MapFact(l.mapConnectPeerApproval(computer), icon: Icons.verified_user_outlined),
        ] else if (!b.person) ...[
          const SizedBox(height: 16),
          Row(key: const Key('agent-connect-contact-side'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 16, color: XColors.textDim),
            const SizedBox(width: 8),
            Expanded(child: Text(l.mapConnectContactSide(computer), style: XText.bodyDim)),
          ]),
        ],
        const SizedBox(height: 16),
        if (done == null) ...[
          OwnerAuthField(controller: _auth, onSubmitted: _busy ? null : (_) => _connect()),
          const SizedBox(height: 8),
          Text(l.commonSameAs(_cli(preview)), style: XText.monoSmall),
          if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
        ] else
          ConnectResultLines(
            outcome: done,
            computer: computer,
            disconnect: false,
            onApproveNow: done.reply?.otherSide.id == null
                ? null
                : () => showDeviceRequestDialog(context, contact: computer, id: done.reply!.otherSide.id!),
            onAskAgain: _busy ? null : _askAgain,
          ),
      ]),
    );
  }
}

/// The disconnect dialog for the line between our [agent] and [contact]'s [peerAgent] (its person when `null`).
/// [onlyThere]: only the other own computer has this line (its agent's counterpart is ours). Its last outcome, if
/// anything was sent.
Future<ConnectOutcome?> showAgentDisconnectDialog(BuildContext context,
    {required String agent,
    required String contact,
    required String? peerAgent,
    required bool own,
    required bool onlyThere}) async {
  final box = OutcomeBox();
  await showXDialog<void>(
      context,
      (_) => _DisconnectDialog(
          agent: agent, contact: contact, peerAgent: peerAgent, own: own, onlyThere: onlyThere, box: box));
  return box.outcome;
}

class _DisconnectDialog extends StatefulWidget {
  const _DisconnectDialog({
    required this.agent,
    required this.contact,
    required this.peerAgent,
    required this.own,
    required this.onlyThere,
    required this.box,
  });
  final String agent;
  final String contact;
  final String? peerAgent;
  final bool own;
  final bool onlyThere;
  final OutcomeBox box;

  @override
  State<_DisconnectDialog> createState() => _DisconnectDialogState();
}

class _DisconnectDialogState extends State<_DisconnectDialog> {
  bool _stopTasks = false;
  bool _ask = true;
  bool _peerStopTasks = false;
  bool _busy = false;
  ConnectOutcome? _done;
  Object? _error;

  bool get _asks => widget.own && widget.peerAgent != null;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final out = await AppScope.read(context).disconnectAgent(disconnectRequestFor(
      agent: widget.agent,
      contact: widget.contact,
      peerAgent: widget.peerAgent,
      own: widget.own,
      stopTasks: _stopTasks,
      ask: _ask,
      peerStopTasks: _peerStopTasks,
    ));
    widget.box.outcome = out;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = out.reply == null ? null : out;
      _error = out.reply == null ? out.error : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final peer = widget.peerAgent;
    final other = peer ?? l.mapPersonOf(widget.contact);
    final done = _done;
    final idle = done == null && !_busy;
    return XDialogShell(
      key: const Key('agent-disconnect-dialog'),
      title: l.mapDisconnectTitle(widget.agent, other),
      icon: Icons.link_off_rounded,
      titleTag: const ExperimentalTag(),
      width: 560,
      actions: done != null
          ? [
              if (done.reply?.otherSide.state == OtherSideState.requested)
                OutlinedButton(
                  key: const Key('agent-disconnect-close'),
                  style: XButtons.secondary(),
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.commonDone),
                )
              else
                FilledButton(
                  key: const Key('agent-disconnect-close'),
                  style: XButtons.primary(),
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.commonDone),
                ),
            ]
          : [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
              TextButton(
                key: const Key('agent-disconnect-ok'),
                style: XButtons.destructive(),
                // A line only the other side drew goes away only by asking it.
                onPressed: _busy || (widget.onlyThere && !_ask) ? null : _go,
                child: busyLabel(_busy, l.mapDisconnectAction),
              ),
            ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MapFact(
          widget.onlyThere && peer != null
              ? l.mapDisconnectWhatThere(peer, widget.contact, widget.agent)
              : l.mapDisconnectWhat(widget.agent),
          icon: Icons.link_off_rounded,
        ),
        const SizedBox(height: 8),
        MapCheck(
          k: const Key('agent-disconnect-tasks'),
          value: _stopTasks,
          label: l.mapDisconnectTasks(widget.contact),
          onChanged: idle ? (v) => setState(() => _stopTasks = v) : null,
        ),
        if (_asks) ...[
          MapCheck(
            k: const Key('agent-disconnect-ask'),
            value: _ask,
            label: l.mapDisconnectAsk(widget.contact, peer!),
            hint: l.mapConnectPeerApproval(widget.contact),
            onChanged: idle ? (v) => setState(() => _ask = v) : null,
          ),
          MapCheck(
            k: const Key('agent-disconnect-peer-tasks'),
            value: _ask && _peerStopTasks,
            label: l.mapDisconnectPeerTasks(peer),
            onChanged: idle && _ask ? (v) => setState(() => _peerStopTasks = v) : null,
          ),
        ],
        if (_error != null) ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
        if (done != null) ...[
          const SizedBox(height: 8),
          ConnectResultLines(
            outcome: done,
            computer: widget.contact,
            disconnect: true,
            onApproveNow: done.reply?.otherSide.id == null
                ? null
                : () => showDeviceRequestDialog(context, contact: widget.contact, id: done.reply!.otherSide.id!),
          ),
        ],
      ]),
    );
  }
}

/// Connect to…: every agent and person on another computer that a line can reach, grouped by computer, and with
/// [here] (the daemon knows local connections) this computer's other agents first. The keyboard path to the same
/// dialogs as drawing a line.
Future<MapNode?> showCounterpartPicker(BuildContext context,
        {required AgentMapGraph graph, required MapNode local, bool here = false}) =>
    showXDialog<MapNode>(context, (ctx) {
      final l = ctx.l;
      final m = AppScope.of(ctx);
      final groups = [
        for (final (i, c) in graph.clusters.indexed)
          if (i > 0 || here)
            (
              i == 0 ? l.devicesThisComputer : c.title,
              [for (final n in c.nodes) if (n.connectable && n.id != local.id) n],
            ),
      ].where((g) => g.$2.isNotEmpty).toList();
      return XDialogShell(
        key: const Key('agent-pick-dialog'),
        title: l.mapPickTitle(local.name),
        icon: Icons.hub_outlined,
        width: 520,
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.commonCancel))],
        child: groups.isEmpty
            ? Text(l.mapPickEmpty, style: XText.bodyDim)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (title, nodes) in groups) ...[
                  SectionLabel(title),
                  for (final n in nodes)
                    InkWell(
                      key: Key('agent-pick-${n.id}'),
                      borderRadius: BorderRadius.circular(XRadius.m),
                      onTap: () => Navigator.pop(ctx, n),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(children: [
                          if (n.person)
                            XAvatar(n.name, size: 28, picture: m.pictureOfContactLabel(n.name))
                          else if (n.here)
                            AgentAvatar(AgentRef(n.name, mine: true), size: 28)
                          else
                            AgentAvatar(AgentRef(n.name, contact: n.contact), size: 28),
                          const SizedBox(width: 12),
                          Expanded(child: Text(mapEndName(l, n), style: XText.body)),
                          Text(mapNodeKind(l, m, null, n), style: XText.meta),
                        ]),
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              ]),
      );
    });

/// The other own computer's request for one connection, answered here as in My devices (the same card: Touch ID,
/// the password, Deny).
Future<void> showDeviceRequestDialog(BuildContext context, {required String contact, required String id}) =>
    showXDialog<void>(context, (_) => _DeviceRequestDialog(contact: contact, id: id));

class _DeviceRequestDialog extends StatefulWidget {
  const _DeviceRequestDialog({required this.contact, required this.id});
  final String contact;
  final String id;

  @override
  State<_DeviceRequestDialog> createState() => _DeviceRequestDialogState();
}

class _DeviceRequestDialogState extends State<_DeviceRequestDialog> {
  bool _seen = false;

  @override
  void initState() {
    super.initState();
    // The request comes with that computer's next status: read the devices again in case it arrived just now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(AppScope.read(context).refreshDevices());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final found = m.waitingRequest(m.ownDevices, widget.contact, widget.id);
    if (found != null) _seen = true;
    return XDialogShell(
      key: const Key('agent-approve-dialog'),
      title: l.mapConnectApproveTitle(widget.contact),
      icon: Icons.verified_user_outlined,
      width: 600,
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonClose))],
      child: switch (found) {
        (final d, final a) => DeviceRequestCard(d, a, key: ValueKey('${d.linkId}-${a.id}')),
        null => Text(_seen ? l.mapConnectApproveDone(widget.contact) : l.mapConnectNotHereYet(widget.contact),
            key: const Key('agent-approve-status'), style: XText.body),
      },
    );
  }
}
