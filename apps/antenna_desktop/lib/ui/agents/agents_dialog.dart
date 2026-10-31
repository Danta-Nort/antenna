// SPDX-License-Identifier: AGPL-3.0-only
// "Connect an agent" (user path): the owner sets the name, links and the required data label (Q-15), and gets a
// token (owner password) and ready-made snippets for Claude Code, Codex and any script. The daemon enforces the
// agent's permissions (SPEC §9): the agent has no owner commands, and the token works only for its links.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/agent_snippets.dart';
import '../../state/agent_status.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../pictures/picture_picker.dart';
import '../security/owner_confirm.dart';
import '../widgets/agent_logo.dart' show knownAgentBrand;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/self_level.dart';
import 'agent_connection_line.dart';
import 'agent_stop_dialog.dart';
import 'ai_apps_card.dart' show AgentStatusChip, statusDetail;
import 'approver_dialog.dart';
import 'connect_widgets.dart' show TokenWarning;
import 'escalate_to.dart';
import 'everyone_switch.dart';
import 'tasks_from.dart';

Future<void> showAgentsDialog(BuildContext context) =>
    showXDialog<void>(context, (_) => const AgentsDialog(), dismissible: false);

class AgentsDialog extends StatefulWidget {
  const AgentsDialog({super.key, this.initialToken, this.initialName, this.initialTokenFile});

  /// For mockups and tests: show an issued token right away.
  final String? initialToken;
  final String? initialTokenFile;
  final String? initialName;

  @override
  State<AgentsDialog> createState() => _AgentsDialogState();
}

class _AgentsDialogState extends State<AgentsDialog> {
  final _name = TextEditingController();
  final _auth = OwnerAuthController();
  int? _label;
  bool _allLinks = true;
  final Set<String> _links = {};

  /// v6: the new agent also reads messages to everyone (off by default).
  bool _everyone = false;
  Object? _error;
  bool _busy = false;
  String? _token;
  String? _tokenFor;

  /// Where the daemon wrote the token (preview.4); `null`: an older daemon, the token itself is shown.
  String? _tokenFile;
  // The default tab comes from the single "MCP on macOS" switch (agent_snippets.dart).
  String _tab = defaultSnippetTab(macos: Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    _token = widget.initialToken;
    _tokenFor = widget.initialName;
    _tokenFile = widget.initialTokenFile;
    // The role the owner chose for new agents (Agents → Role preset); none chosen: nothing preselected (Q-15).
    _label = AppearanceScope.read(context)?.rolePreset?.level;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).refreshAgents();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _auth.dispose();
    super.dispose();
  }

  String? get _formProblem {
    final n = _name.text.trim();
    final l = context.l;
    if (n.isEmpty) return l.agentErrName;
    if (!RegExp(r'^[A-Za-z0-9._-]{1,40}$').hasMatch(n)) return l.agentErrNameChars;
    if (_label == null) return l.agentErrLabel;
    if (!_allLinks && _links.isEmpty) return l.agentErrLinks;
    return null;
  }

  Future<void> _issue() async {
    final problem = _formProblem;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = AppScope.read(context);
    final l = context.l;
    final name = _name.text.trim();
    final (r, err) = await m.addAgent(
      name: name,
      localLevel: _label!,
      auth: _auth.auth(m, l.touchIdReasonAgentToken(cutForPrompt(name))),
      links: _allLinks ? null : _links.toList(),
      everyone: _everyone,
    );
    _auth.password.clear();
    if (!mounted) return;
    final fellBack = _auth.fellBack(l, m, err);
    setState(() {
      _busy = false;
      _error = fellBack ? null : err;
      if (r != null) {
        _token = r.token;
        _tokenFor = r.name;
        _tokenFile = r.tokenFile;
      }
    });
  }

  @override
  Widget build(BuildContext context) => XDialogShell(
        title: _token == null ? context.l.agentConnect : context.l.agentConnected(_tokenFor ?? ''),
        icon: Icons.smart_toy_outlined,
        subtitle: _token == null ? context.l.agentAbout : null,
        width: 860,
        actions: [
          if (_token != null) ...[
            TextButton(
              onPressed: () => setState(() {
                _token = null;
                _name.clear();
                _label = null;
              }),
              child: Text(context.l.agentAnother),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonDone)),
          ] else ...[
            TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.commonClose)),
            FilledButton(
              key: const Key('agent-issue'),
              onPressed: _busy ? null : _issue,
              child: Text(context.l.agentIssueToken),
            ),
          ],
        ],
        child: _token == null ? _form(context) : _issued(context, _token!),
      );

  Widget _form(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (m.agents.isNotEmpty) ...[
        SectionLabel(l.agentAlreadyConnected),
        for (final a in m.agents) AgentRow(a),
        const SizedBox(height: 16),
      ],
      SectionLabel(l.agentNew),
      TextField(
        key: const Key('agent-name'),
        controller: _name,
        autofocus: true,
        style: XText.body.copyWith(fontFamily: XFonts.mono),
        decoration: InputDecoration(labelText: l.agentName, hintText: 'jarvis'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Text(l.agentDataLabel, style: XText.label),
        const SizedBox(width: 8),
        Text(l.agentDataLabelHint, style: XText.monoSmall),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final d in DataLabel.all) DataLabelCard(d, selected: _label == d.level, onTap: () => setState(() => _label = d.level)),
      ]),
      if (_label != null) ...[
        const SizedBox(height: 8),
        Text(
          l.agentNoWriteDown(_label!),
          style: XText.bodyDim.copyWith(fontSize: 12),
        ),
      ],
      const SizedBox(height: 16),
      Row(children: [
        Text(l.agentLinks, style: XText.label),
        const SizedBox(width: 12),
        ChoiceChip(
          label: Text(l.agentAllLinks),
          selected: _allLinks,
          onSelected: (_) => setState(() => _allLinks = true),
          showCheckmark: false,
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: Text(l.agentSelectedLinks),
          selected: !_allLinks,
          onSelected: (_) => setState(() => _allLinks = false),
          showCheckmark: false,
        ),
      ]),
      if (!_allLinks) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in m.contacts)
            FilterChip(
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(c.label),
                const SizedBox(width: 8),
                TrustBadge(c.trust, size: 15),
              ]),
              selected: _links.contains(c.label),
              onSelected: (v) => setState(() => v ? _links.add(c.label) : _links.remove(c.label)),
            ),
        ]),
      ],
      NewAgentEveryoneSwitch(value: _everyone, onChanged: (v) => setState(() => _everyone = v)),
      const SizedBox(height: 16),
      OwnerAuthField(controller: _auth, onSubmitted: (_) => _issue()),
      if (_error != null)
        _error is String ? ErrorLine(_error! as String) : ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      const SizedBox(height: 16),
      const NewMessagesOnlyNote(),
      const SizedBox(height: 8),
      const _RemoteAgentNote(),
    ]);
  }

  Widget _issued(BuildContext context, String token) {
    final m = AppScope.of(context);
    final xPath = m.binaries?.cli;
    final socket = m.socketNeedsEnv ? m.socketPath : null;
    final l = context.l;
    final tokenFile = _tokenFile;
    final snippets = agentSnippets(
      l,
      name: _tokenFor ?? 'agent',
      token: token,
      tokenFile: tokenFile,
      xPath: xPath ?? 'antenna',
      socket: socket,
      macos: Platform.isMacOS,
      exampleContact: m.contacts.isEmpty ? 'bob' : m.contacts.first.label,
    );
    final current = snippets.firstWhere((s) => s.id == _tab, orElse: () => snippets.first);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (tokenFile != null)
        // The token stays in a file only the owner can read; every snippet below names the file.
        Container(
          key: const Key('agent-token-file'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.m)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.key_off_outlined, size: 18, color: XColors.accent),
              const SizedBox(width: 8),
              Expanded(child: Text(l.agentTokenFileTitle, style: XText.title)),
            ]),
            const SizedBox(height: 8),
            Text(tokenFile, style: XText.mono.copyWith(color: XColors.text)),
            const SizedBox(height: 8),
            Text(l.agentTokenFileNote, style: XText.bodyDim),
          ]),
        )
      else
        // An older daemon without token files: the token has to be shown, with a plain warning and a way to replace it.
        TokenWarning(token: token, agent: _tokenFor ?? ''),
      const SizedBox(height: 12),
      if (xPath == null)
        Text(
          l.agentCliNotFound,
          style: XText.monoSmall.copyWith(color: XColors.warn),
        )
      else
        Text(l.agentCliPath(xPath), style: XText.monoSmall),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in snippets)
          ChoiceChip(
            key: Key('snippet-${s.id}'),
            label: Text(s.title),
            selected: s.id == current.id,
            onSelected: (_) => setState(() => _tab = s.id),
            showCheckmark: false,
          ),
      ]),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: XColors.bg0.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(XRadius.m),
          border: Border.all(color: XColors.lineStrong),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(children: [
              Expanded(child: Text(current.where.toUpperCase(), style: XText.overline)),
              _CopyButton(current.text, key: Key('copy-${current.id}')),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SelectableText(current.text, style: XText.mono.copyWith(color: XColors.text, fontSize: 11, height: 1.5)),
          ),
        ]),
      ),
      if (current.note != null) ...[
        const SizedBox(height: 8),
        Text(current.note!, style: XText.bodyDim.copyWith(fontSize: 12)),
      ],
      const SizedBox(height: 16),
      const NewMessagesOnlyNote(),
      const SizedBox(height: 8),
      const _RemoteAgentNote(),
    ]);
  }
}

/// One data label to choose (Q-15): here and in Code mode's "Start agent".
class DataLabelCard extends StatelessWidget {
  const DataLabelCard(this.l, {super.key, required this.selected, required this.onTap});
  final DataLabel l;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = l.level == 0 ? XColors.textDim : XColors.trustColor(l.level);
    return InkWell(
      key: Key('label-${l.level}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(XRadius.m),
      child: AnimatedContainer(
        duration: XMotion.fast,
        width: 256,
        padding: const EdgeInsets.all(8),
        decoration: selected
            ? xGlow(radius: XRadius.m, color: c, strength: 0.8)
            : BoxDecoration(
                borderRadius: BorderRadius.circular(XRadius.m),
                border: Border.all(color: XColors.line),
                color: XColors.bg2,
              ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${l.level}', style: XText.monoStrong.copyWith(color: c, fontSize: 20)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.title(context.l), style: XText.label.copyWith(color: selected ? XColors.text : XColors.textDim)),
              const SizedBox(height: 2),
              Text(l.hint(context.l), style: XText.monoSmall.copyWith(fontSize: 11, height: 1.35)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class AgentRow extends StatelessWidget {
  const AgentRow(this.a, {super.key, this.onStart, this.showEveryone = false, this.showCodeWake = false});
  final AgentInfo a;

  /// Code mode: the switch "Wake on new messages" (window side, D-UI-23; no password: it only types fixed lines).
  final bool showCodeWake;

  /// Code mode: start this agent in a terminal in the window.
  final VoidCallback? onStart;

  /// v6: the switch "Sees messages to everyone" (CONTROL §20); the daemon, not the agent, applies it.
  final bool showEveryone;

  /// Turning it on widens what the agent reads: the owner password. Turning it off: no password.
  Future<void> _setEveryone(BuildContext context, bool on) async {
    final m = AppScope.read(context);
    Object? err;
    if (on) {
      (_, err) = await confirmOwner(
        context,
        action: context.l.agentEveryoneOnAction(a.name),
        detail: context.l.agentEveryoneOnHint,
        cli: 'antenna agent set ${a.name} --everyone on',
        run: (auth) => m.setAgentEveryone(a.name, everyone: true, auth: auth),
      );
    } else {
      err = await m.setAgentEveryone(a.name, everyone: false);
    }
    if (err != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
    }
  }

  Future<void> _remove(BuildContext context) async {
    final m = AppScope.read(context);
    final (_, err) = await confirmOwner(context,
        action: context.l.agentRevokeAction(a.name),
        cli: 'antenna agent remove ${a.name}',
        run: (auth) => m.removeAgent(a.name, auth));
    if (err != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final st = AgentStatus.of(a);
    final app = m.appOfAgent(a.name);
    final detail = statusDetail(l, st, m.now(), app: app?.name);
    final tasks = a.tasksFrom;
    return Padding(
        key: Key('agent-row-${a.name}'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          // My agent: its AI's mark only when the window knows it (the app it connected, the CLI it started).
          XAvatar(a.name,
              size: 34, agent: true, brand: knownAgentBrand(m, a.name), picture: m.pictureOfMine(agent: a.name)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(a.name, style: XText.title),
                AgentStatusChip(st, key: Key('agent-status-${a.name}')),
              ]),
              if (detail != null && detail.isNotEmpty) Text(detail, style: XText.meta),
              Text(
                [
                  if (a.localLevel != null) l.agentRowLabel(a.localLevel!),
                  a.links == null ? l.agentAllLinks : l.agentRowLinks(a.links!.join(', ')),
                  a.ceiling == null ? l.agentRowClean : l.agentRowCeiling(a.ceiling!),
                ].join(' · '),
                style: XText.monoSmall,
              ),
              // Task authority is experimental (D-94): a tooltip here, since a tag on every agent's row would be noise;
              // the tag itself stands next to the controls that change it.
              if (tasks != null)
                Tooltip(
                  message: '${l.experimentalTag} · ${l.experimentalTip}',
                  child: Text(
                    tasks.isEmpty
                        ? l.agentRowTasksNone
                        : l.agentRowTasks([
                            for (final n in tasks)
                              labelWithSelfMark(l, n, m.contacts.where((c) => c.label == n).firstOrNull?.trust),
                          ].join(', ')),
                    key: Key('agent-tasks-${a.name}'),
                    style: XText.meta.copyWith(color: tasks.isEmpty ? XColors.textMute : XColors.accent),
                  ),
                ),
              AgentConnectionLines(a),
              ApproverLines(a),
              if (showEveryone && a.everyone != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(children: [
                    SizedBox(
                      height: 26,
                      child: FittedBox(
                        child: Switch(
                          key: Key('agent-everyone-${a.name}'),
                          value: a.everyone!,
                          onChanged: (v) => _setEveryone(context, v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Text(context.l.agentEveryone, style: XText.label.copyWith(color: XColors.text)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        a.everyone! ? context.l.agentEveryoneOnHint : context.l.agentEveryoneOffHint,
                        overflow: TextOverflow.ellipsis,
                        style: XText.meta,
                      ),
                    ),
                  ]),
                ),
              if (showCodeWake)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(children: [
                    SizedBox(
                      height: 26,
                      child: FittedBox(
                        child: Switch(
                          key: Key('agent-code-wake-${a.name}'),
                          value: m.codeWakeOn(a.name),
                          onChanged: (v) => m.setCodeWake(a.name, v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Text(l.codeWakeSwitch, style: XText.label.copyWith(color: XColors.text)),
                    const SizedBox(width: 8),
                    Flexible(
                      // Experimental (D-94): said in the tooltip, as for task authority, not on every row.
                      child: Tooltip(
                        message: '${l.codeWakeSwitchHint}\n${l.experimentalTag} · ${l.experimentalTip}',
                        child: Text(l.codeWakeRowHint, overflow: TextOverflow.ellipsis, style: XText.meta),
                      ),
                    ),
                  ]),
                ),
              // "Restore after an update" (D-103), next to the wake switch; the window settings file keeps it.
              if (showCodeWake && m.agentRunStore != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(children: [
                    SizedBox(
                      height: 26,
                      child: FittedBox(
                        child: Switch(
                          key: Key('agent-code-restore-${a.name}'),
                          value: m.codeRestoreOn(a.name),
                          onChanged: (v) => m.setCodeRestore(a.name, v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Text(l.codeRestoreSwitch, style: XText.label.copyWith(color: XColors.text)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Tooltip(
                        message: '${l.codeRestoreSwitchHint}\n${l.experimentalTag} · ${l.experimentalTip}',
                        child: Text(l.codeRestoreRowHint, overflow: TextOverflow.ellipsis, style: XText.meta),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
          if (tasks != null)
            IconButton(
              key: Key('agent-tasks-edit-${a.name}'),
              tooltip: '${l.appsTasksFrom} · ${l.experimentalTag}',
              onPressed: () => showTasksFromDialog(context, a.name),
              icon: const Icon(Icons.task_alt_rounded, size: 18),
            ),
          if (AppScope.of(context).questionsSupported && a.localModel == null)
            IconButton(
              key: Key('agent-escalate-edit-${a.name}'),
              tooltip: '${a.escalateTo == null ? l.escalateToOwner : l.escalateToContact(a.escalateTo!)} · '
                  '${l.experimentalTag}',
              onPressed: () => showEscalateToDialog(context, a.name),
              icon: const Icon(Icons.contact_support_outlined, size: 18),
            ),
          // Approver agents (CONTROL §31; experimental): only once the daemon answered `approvers`
          if (m.approversKnown && a.localModel == null)
            IconButton(
              key: Key('agent-approver-edit-${a.name}'),
              tooltip: '${l.approverAction} · ${l.experimentalTag}',
              onPressed: () => showApproverDialog(context, agent: a.name),
              icon: Icon(m.approverOf(a.name) == null ? Icons.how_to_reg_outlined : Icons.how_to_reg,
                  size: 18, color: m.approverOf(a.name) == null ? null : XColors.accent),
            ),
          // The stop switch (CONTROL §33; experimental): for an agent that runs now, here or through its daemon.
          if (m.agentRunsNow(a.name) && (m.daemonProto >= 7 || (m.runOf(a.name)?.alive ?? false)))
            IconButton(
              key: Key('agent-stop-${a.name}'),
              tooltip: '${l.agentStopAction} · ${l.experimentalTag}',
              onPressed: () => stopAgentWithConfirm(context, a.name),
              icon: Icon(Icons.stop_circle_outlined, size: 18, color: XColors.danger),
            ),
          if (onStart != null)
            if (AppScope.of(context).runOf(a.name)?.alive ?? false)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(context.l.codeRunningHere, style: XText.meta.copyWith(color: XColors.ok)),
              )
            else
              TextButton.icon(
                key: Key('agent-start-${a.name}'),
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow_rounded, size: 17),
                label: Text(context.l.codeRunInWindow),
              ),
          // The agent's picture, as contacts see it next to its messages (CONTROL §28; nothing for an older daemon)
          if (m.picturesSupported)
            Tooltip(
              message: l.agentPictureTip(a.name),
              child: TextButton(
                key: Key('agent-picture-${a.name}'),
                onPressed: () => showPicturePicker(context, agent: a.name),
                child: Text(l.agentPictureAction),
              ),
            ),
          TextButton(onPressed: () => _remove(context), child: Text(context.l.agentRevoke)),
        ]),
      );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton(this.text, {super.key});
  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
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

/// The agent sees only what arrives after it is connected (CONTROL §5, D-30: a privacy property, not a gap), and how
/// to give it something older.
class NewMessagesOnlyNote extends StatelessWidget {
  const NewMessagesOnlyNote({super.key});

  @override
  Widget build(BuildContext context) => Row(
        key: const Key('agent-new-messages-only'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.history_toggle_off_rounded, size: 18, color: XColors.textDim),
          const SizedBox(width: 8),
          Expanded(child: Text(context.l.agentSeesNewOnly, style: XText.bodyDim)),
        ],
      );
}

class _RemoteAgentNote extends StatelessWidget {
  const _RemoteAgentNote();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(XRadius.m),
          border: Border.all(color: XColors.line),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.dns_outlined, size: 18, color: XColors.accent),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l.agentRemoteNote,
              style: XText.bodyDim,
            ),
          ),
        ]),
      );
}

/// What an agent of this computer may answer in the owner's place (CONTROL §31; experimental): "Can approve for: …"
/// as the owner set it here, and the own computers whose requests it answers, set there (`session.approves`).
class ApproverLines extends StatelessWidget {
  const ApproverLines(this.a, {super.key});
  final AgentInfo a;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final mine = m.approverOf(a.name);
    final there = [for (final x in a.approves) if (x.device != null) x.device!];
    if (mine == null && there.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: '${l.experimentalTag} · ${l.experimentalTip}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (mine != null)
          Text(
            l.approverRow(approverScope(l, mine.agents, mine.kinds)),
            key: Key('agent-approver-${a.name}'),
            style: XText.meta.copyWith(color: XColors.accent),
          ),
        if (there.isNotEmpty)
          Text(
            l.approverRowThere(there.join(', ')),
            key: Key('agent-approver-there-${a.name}'),
            style: XText.meta,
          ),
      ]),
    );
  }
}
