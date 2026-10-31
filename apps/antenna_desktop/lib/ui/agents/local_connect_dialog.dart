// SPDX-License-Identifier: AGPL-3.0-only
// Connecting two agents of this computer (CONTROL §30 `agent_connect` with `local`; D-UI-47, experimental): the dialog
// says what will be set before anything is sent. The line itself: A's messages without an address go to B. The
// choices, all on by default: B's go to A too (`ask`), A's messages are tasks for B (`peer_tasks`), B's are tasks for A
// (`tasks`). What keeps it safe is the daemon's: the messages stay on this computer, a message carries what its writer
// has read, a more sensitive agent cannot write to a less sensitive one, and chains between agents are limited; the
// dialog says so. Connecting takes the owner password, never kept; disconnecting takes none (D-84).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/agent_map.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/x_buttons.dart';
import 'agent_connect_dialog.dart';
import 'agent_map_text.dart';

/// The error of a local connect or disconnect in words: a daemon built before local connections says so plainly.
String localErrorText(AppLocalizations l, Object e) =>
    e is XControlException && localConnectionsUnknown(e) ? l.mapDropLocalUnsupported : describeError(l, e);

/// The connect dialog for a line from [from] to [to], both agents of this computer; its last outcome, if anything was
/// sent.
Future<ConnectOutcome?> showLocalConnectDialog(BuildContext context,
    {required MapNode from, required MapNode to}) async {
  final box = OutcomeBox();
  await showXDialog<void>(context, (_) => _LocalConnectDialog(from: from, to: to, box: box));
  return box.outcome;
}

class _LocalConnectDialog extends StatefulWidget {
  const _LocalConnectDialog({required this.from, required this.to, required this.box});
  final MapNode from;
  final MapNode to;
  final OutcomeBox box;

  @override
  State<_LocalConnectDialog> createState() => _LocalConnectDialogState();
}

class _LocalConnectDialogState extends State<_LocalConnectDialog> {
  final _auth = OwnerAuthController();
  bool _ask = true;
  bool _peerTasks = true;
  bool _tasks = true;
  bool _busy = false;
  ConnectOutcome? _done;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // Connected already: the dialog starts from what is set, so Connect changes only what the owner changes.
    final agents = AppScope.read(context).agents;
    final a = agents.where((x) => x.name == widget.from.name).firstOrNull;
    final b = agents.where((x) => x.name == widget.to.name).firstOrNull;
    final ab = a?.localRoutes?.where((r) => r.agent == widget.to.name).firstOrNull;
    final ba = b?.localRoutes?.where((r) => r.agent == widget.from.name).firstOrNull;
    if (ab != null || ba != null) {
      _tasks = ab?.tasks ?? false;
      _peerTasks = ba?.tasks ?? false;
      final cp = b?.counterpart;
      _ask = cp != null && cp.local && cp.agent == widget.from.name;
    }
  }

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  LocalConnectRequest _request(String password) => LocalConnectRequest(
        name: widget.from.name,
        local: widget.to.name,
        tasks: _tasks,
        peerTasks: _peerTasks,
        ask: _ask,
        password: password,
      );

  Future<void> _connect() async {
    final m = AppScope.read(context);
    final l = context.l;
    // The owner's password, or one touch where Touch ID is set up (D-131), as for every connection
    final auth = _auth.auth(m, touchIdConfirmReason(l, l.mapLocalTitle(widget.from.name, widget.to.name)));
    setState(() {
      _busy = true;
      _error = null;
    });
    final out = await m.connectLocal(_request(''), auth: auth);
    widget.box.outcome = out;
    _auth.password.clear();
    if (!mounted) return;
    final fellBack = out.reply == null && _auth.fellBack(l, m, out.error);
    setState(() {
      _busy = false;
      // A refusal keeps the form, so the owner can fix the password and try again.
      _done = out.reply == null ? null : out;
      _error = out.reply == null && !fellBack ? out.error : null;
    });
  }

  String _cli(LocalConnectRequest r) => [
        'antenna agent connect',
        shellArg(r.name),
        '--local ${shellArg(r.local)}',
        r.tasks == false ? '--no-tasks' : '--tasks',
        r.peerTasks == false ? '--no-peer-tasks' : '--peer-tasks',
        if (!r.ask) '--here-only',
      ].join(' ');

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final look = AppearanceScope.maybeOf(context);
    final a = widget.from;
    final b = widget.to;
    final done = _done;
    final idle = done == null && !_busy;
    Widget note(String text) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.shield_outlined, size: 14, color: XColors.textDim),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: XText.bodyDim)),
          ]),
        );
    return XDialogShell(
      key: const Key('local-connect-dialog'),
      title: l.mapLocalTitle(a.name, b.name),
      icon: Icons.hub_outlined,
      titleTag: const ExperimentalTag(),
      width: 640,
      actions: done != null
          ? [
              FilledButton(
                key: const Key('local-connect-close'),
                style: XButtons.primary(),
                onPressed: () => Navigator.pop(context),
                child: Text(l.commonDone),
              ),
            ]
          : [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
              FilledButton(
                key: const Key('local-connect-ok'),
                style: XButtons.primary(),
                onPressed: _busy ? null : _connect,
                child: busyLabel(_busy, l.mapConnectAction),
              ),
            ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MapConnectEnds(a, b,
            aWhere: l.devicesThisComputer,
            bWhere: l.devicesThisComputer,
            aKind: mapNodeKind(l, m, look, a),
            bKind: mapNodeKind(l, m, look, b)),
        const SizedBox(height: 16),
        MapFact(l.mapConnectPeerLine(a.name, b.name)),
        MapCheck(
          k: const Key('local-connect-ask'),
          value: _ask,
          label: l.mapLocalAsk(b.name, a.name),
          onChanged: idle ? (v) => setState(() => _ask = v) : null,
        ),
        MapCheck(
          k: const Key('local-connect-peer-tasks'),
          value: _peerTasks,
          label: l.mapConnectTasks(a.name, b.name),
          onChanged: idle ? (v) => setState(() => _peerTasks = v) : null,
        ),
        MapCheck(
          k: const Key('local-connect-tasks'),
          value: _tasks,
          label: l.mapConnectTasks(b.name, a.name),
          onChanged: idle ? (v) => setState(() => _tasks = v) : null,
        ),
        const SizedBox(height: 12),
        Container(
          key: const Key('local-connect-rules'),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: xPanel(fill: XColors.bg2, border: XColors.line, radius: XRadius.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            note(l.mapLocalStays),
            note(l.mapLocalTaint(a.name, b.name)),
            note(l.mapLocalLevels),
            note(l.mapLocalChains),
          ]),
        ),
        const SizedBox(height: 16),
        if (done == null) ...[
          OwnerAuthField(controller: _auth, onSubmitted: _busy ? null : (_) => _connect()),
          const SizedBox(height: 8),
          Text(l.commonSameAs(_cli(_request(''))), style: XText.monoSmall),
          if (_error != null) ErrorLine(localErrorText(l, _error!), detail: errorDetail(_error!)),
        ] else
          Column(key: const Key('local-connect-result'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.check_circle_rounded, size: 18, color: XColors.ok),
              const SizedBox(width: 8),
              Expanded(child: Text(l.mapConnectDoneHere, style: XText.body)),
            ]),
            if (done.reply?.otherSide.state == OtherSideState.notAsked)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l.mapLocalNotAsked(b.name), style: XText.bodyDim),
              ),
          ]),
      ]),
    );
  }
}

/// The disconnect dialog for the connection between [agent] and [other], both agents of this computer; its last
/// outcome, if anything was sent.
Future<ConnectOutcome?> showLocalDisconnectDialog(BuildContext context,
    {required String agent, required String other}) async {
  final box = OutcomeBox();
  await showXDialog<void>(context, (_) => _LocalDisconnectDialog(agent: agent, other: other, box: box));
  return box.outcome;
}

class _LocalDisconnectDialog extends StatefulWidget {
  const _LocalDisconnectDialog({required this.agent, required this.other, required this.box});
  final String agent;
  final String other;
  final OutcomeBox box;

  @override
  State<_LocalDisconnectDialog> createState() => _LocalDisconnectDialogState();
}

class _LocalDisconnectDialogState extends State<_LocalDisconnectDialog> {
  bool _busy = false;
  ConnectOutcome? _done;
  Object? _error;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final out =
        await AppScope.read(context).disconnectLine(LocalDisconnectRequest(name: widget.agent, local: widget.other));
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
    final done = _done;
    return XDialogShell(
      key: const Key('local-disconnect-dialog'),
      title: l.mapDisconnectTitle(widget.agent, widget.other),
      icon: Icons.link_off_rounded,
      titleTag: const ExperimentalTag(),
      width: 560,
      actions: done != null
          ? [
              FilledButton(
                key: const Key('local-disconnect-close'),
                style: XButtons.primary(),
                onPressed: () => Navigator.pop(context),
                child: Text(l.commonDone),
              ),
            ]
          : [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
              TextButton(
                key: const Key('local-disconnect-ok'),
                style: XButtons.destructive(),
                onPressed: _busy ? null : _go,
                child: busyLabel(_busy, l.mapDisconnectAction),
              ),
            ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MapFact(l.mapLocalDisconnectWhat(widget.agent, widget.other), icon: Icons.link_off_rounded),
        MapFact(l.mapLocalDropsUnread, icon: Icons.mark_email_unread_outlined),
        if (_error != null) ErrorLine(localErrorText(l, _error!), detail: errorDetail(_error!)),
        if (done != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(key: const Key('local-disconnect-result'), children: [
              Icon(Icons.check_circle_rounded, size: 18, color: XColors.ok),
              const SizedBox(width: 8),
              Expanded(child: Text(l.mapDisconnectDone, style: XText.body)),
            ]),
          ),
      ]),
    );
  }
}
