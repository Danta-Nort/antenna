// SPDX-License-Identifier: AGPL-3.0-only
// Pieces of the Connect dialog that other screens use too: the live status line, a note, a copyable code block, the
// token warning for older daemons, and Disconnect.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_status.dart';
import '../../state/ai_apps.dart';
import '../../state/ai_apps_model.dart';
import '../../state/messages.dart';
import '../../state/owner_auth.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import 'ai_apps_card.dart';

/// "Waiting for the app" → "Connected", live (the dialog polls `agent_list`; the daemon's `agent` event is faster).
class ConnectLiveStatus extends StatelessWidget {
  const ConnectLiveStatus({super.key, required this.app, required this.agent, this.waiting});
  final AiAppDef app;
  final String agent;

  /// The line while the app has not called yet, when the steps above already say what to do.
  final String? waiting;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final st = AgentStatus.of(m.agents.where((a) => a.name == agent).firstOrNull);
    final detail = st.state == AgentLinkState.waiting && waiting != null
        ? waiting
        : statusDetail(l, st, m.now(), app: app.name);
    return Container(
      key: const Key('connect-live-status'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(color: XColors.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AgentStatusChip(st),
        const SizedBox(width: 8),
        Expanded(child: Text(detail ?? '', style: XText.bodyDim)),
      ]),
    );
  }
}

class ConnectNote extends StatelessWidget {
  const ConnectNote(this.icon, this.text, {super.key});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: XColors.textDim)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: XText.bodyDim)),
      ]);
}

/// Monospaced text with a copy button.
class CodeBlock extends StatelessWidget {
  const CodeBlock(this.text, {super.key, this.label});
  final String text;
  final String? label;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: XColors.bg2,
          borderRadius: BorderRadius.circular(XRadius.m),
          border: Border.all(color: XColors.line),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text((label ?? '').toUpperCase(), style: XText.overline)),
            CopyButton(text),
          ]),
          SelectableText(text, style: XText.mono.copyWith(color: XColors.text, fontSize: 11, height: 1.5)),
        ]),
      );
}

class CopyButton extends StatefulWidget {
  const CopyButton(this.text, {super.key});
  final String text;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: widget.text));
          if (mounted) setState(() => _done = true);
        },
        icon: Icon(_done ? Icons.check : Icons.copy_rounded, size: 15),
        label: Text(_done ? context.l.agentCopied : context.l.agentCopy),
      );
}

/// A token that has to be shown (an older daemon without token files): a plain warning next to it, and a way to
/// replace it at once if it went somewhere it should not have.
class TokenWarning extends StatefulWidget {
  const TokenWarning({super.key, required this.token, required this.agent});
  final String token;
  final String agent;

  @override
  State<TokenWarning> createState() => _TokenWarningState();
}

class _TokenWarningState extends State<TokenWarning> {
  late String _token = widget.token;
  Object? _error;

  Future<void> _rotate() async {
    final l = context.l;
    final m = AppScope.read(context);
    AppAgentToken? issued;
    final (_, err) = await confirmOwner(context,
        action: l.tokenRevokeNew,
        cli: 'antenna agent token ${widget.agent}',
        reason: l.touchIdReasonAgentToken(cutForPrompt(widget.agent)), run: (auth) async {
      final (r, e) = await m.rotateAgentToken(widget.agent, auth);
      issued = r;
      return e;
    });
    if (!mounted) return;
    setState(() {
      _error = err;
      if (issued case final r?) _token = r.token;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Container(
      key: const Key('token-warning'),
      padding: const EdgeInsets.all(12),
      decoration: xGlow(radius: XRadius.m, color: XColors.warn, strength: 0.55, fill: XColors.bg2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: XColors.warn),
          const SizedBox(width: 8),
          Expanded(child: Text(l.tokenWarn, style: XText.title.copyWith(fontSize: 14))),
        ]),
        const SizedBox(height: 8),
        CodeBlock(_token),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('token-rotate'),
            onPressed: _rotate,
            icon: const Icon(Icons.autorenew_rounded, size: 16),
            label: Text(l.tokenRevokeNew),
          ),
        ),
        if (_error != null) ErrorLine(describeError(l, _error!)),
      ]),
    );
  }
}

/// Disconnect: what is removed from the app's file and which agent is revoked, then the password.
Future<void> confirmDisconnectApp(BuildContext context, AiAppRow row) async {
  final m = AppScope.read(context);
  final l = context.l;
  final app = row.app;
  final plan = m.planDisconnect(app);
  final agent = row.agent?.name;
  final detail = [
    if (plan != null) l.disconnectFile(plan.path),
    if (plan == null && app.config == null) l.disconnectByHand(app.name),
    if (agent != null) l.disconnectAgent(agent),
  ].join('\n');
  final Object? err;
  if (agent == null) {
    err = await m.disconnectApp(app, auth: const PasswordAuth(''));
  } else {
    (_, err) = await confirmOwner(context,
        action: l.disconnectTitle(app.name),
        detail: detail,
        cli: 'antenna agent remove $agent',
        run: (auth) => m.disconnectApp(app, auth: auth, agent: agent));
  }
  if (err != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(l, err))));
  }
}
