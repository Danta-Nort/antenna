// SPDX-License-Identifier: AGPL-3.0-only
// "Stop agent and its processes" (CONTROL §33, experimental; state/agent_stop.dart): the confirmation says plainly what
// is stopped and what is not, then the daemon stops it and the window says what it took. No password: stopping only
// makes things safer. The same dialog for an agent here (Code mode, Agents) and on another own computer (My devices).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/agent_stop.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/x_buttons.dart';

/// Ask, stop [agent] (of the own computer [computer], or of this one), and show what came of it.
Future<void> stopAgentWithConfirm(BuildContext context, String agent, {String? computer}) async {
  final ok = await showXDialog<bool>(context, (_) => AgentStopDialog(agent: agent, computer: computer)) ?? false;
  if (!ok || !context.mounted) return;
  final m = AppScope.read(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l = context.l;
  final r = computer == null ? await m.stopAgentAndProcesses(agent) : await m.stopDeviceAgent(computer, agent);
  messenger?.showSnackBar(SnackBar(
    key: const Key('agent-stop-result'),
    content: Text(agentStopResultText(l, r)),
  ));
}

/// The notice after a stop, in words.
String agentStopResultText(AppLocalizations l, AgentStopResult r) {
  final a = r.agent;
  final c = r.computer;
  final reply = r.reply;
  if (reply == null) {
    final err = r.error;
    if (r.terminalOnly) {
      return err == null ? l.agentStoppedTerminalOnly(a) : l.agentStoppedTerminalError(a, describeError(l, err));
    }
    return l.agentStopFailed(a, err == null ? '' : describeError(l, err));
  }
  final main = switch (reply.how) {
    StopHow.none => c == null ? l.agentStoppedNone(a) : l.agentStoppedNoneOn(a, c),
    StopHow.app => c == null ? l.agentStoppedApp(a) : l.agentStoppedAppOn(a, c),
    _ when c != null => l.agentStoppedOn(a, c, reply.processes),
    _ when reply.processes == 0 => l.agentStopped(a),
    _ => l.agentStoppedProcesses(a, reply.processes),
  };
  // The process names are the system's (another computer's too): plain text, a few of them.
  final names = [for (final n in reply.names.take(6)) _plain(n)].where((n) => n.isNotEmpty).toList();
  return [
    if (names.isEmpty || reply.how == StopHow.none) main else '$main (${names.join(', ')})',
    if (reply.left > 0) l.agentStoppedLeft(reply.left),
  ].join(' · ');
}

/// A process name as one short line: control and format characters dropped, at most 32 characters.
String _plain(String s) {
  final kept = s.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]'), '').trim();
  return kept.length <= 32 ? kept : '${kept.substring(0, 31)}…';
}

/// The confirmation: what is stopped and what is not; Cancel / Stop agent.
class AgentStopDialog extends StatelessWidget {
  const AgentStopDialog({super.key, required this.agent, this.computer});
  final String agent;
  final String? computer;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    Widget point(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: XColors.textDim)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: XText.body)),
          ]),
        );
    return XDialogShell(
      key: const Key('agent-stop-dialog'),
      title: computer == null ? l.agentStopTitle(agent) : l.agentStopTitleOn(agent, computer!),
      icon: Icons.stop_circle_outlined,
      titleTag: const ExperimentalTag(key: Key('experimental-agent-stop')),
      width: 560,
      actions: [
        TextButton(
          key: const Key('agent-stop-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.commonCancel),
        ),
        TextButton.icon(
          key: const Key('agent-stop-confirm'),
          style: XButtons.destructive(),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.stop_rounded, size: 16),
          label: Text(l.agentStopConfirm),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        point(Icons.account_tree_outlined, l.agentStopWhat),
        point(Icons.laptop_mac_outlined, l.agentStopMac),
        point(Icons.apps_outlined, l.agentStopApps),
        const SizedBox(height: 4),
        Text(l.agentStopNoPassword, style: XText.bodyDim),
      ]),
    );
  }
}
