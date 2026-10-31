// SPDX-License-Identifier: AGPL-3.0-only
// Code mode: "Start agent". Pick an agent (or create one), the program and the folder; the owner password lets the
// daemon issue the agent's token (`agent_add` / `agent_token`). The token goes only into the program's environment:
// it is never shown, copied or saved. The window remembers the program and folder per agent (window.json), not the
// token. "Set up this folder" (agent_setup_section.dart) writes what the owner ticked into the folder before the start.

import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_launch.dart';
import '../../state/agent_setup.dart' show AgentSetupException;
import '../../state/agent_snippets.dart';
import '../../state/appearance.dart';
import '../../state/code_mode.dart';
import '../../theme/x_theme.dart';
import '../agents/agents_dialog.dart' show DataLabelCard;
import '../agents/everyone_switch.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/agent_logo.dart' show knownAgentBrand;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import 'agent_setup_section.dart';
import 'agents_detected.dart' show RolePresetChoice;
import 'code_text.dart';

/// The folder chooser (the system dialog; tests put in their own).
abstract class FolderChooser {
  Future<String?> pick(String confirm);

  static FolderChooser instance = _SystemFolderChooser();
}

class _SystemFolderChooser implements FolderChooser {
  @override
  Future<String?> pick(String confirm) => fs.getDirectoryPath(confirmButtonText: confirm);
}

/// [agent]: start this agent (from the Agents section); [spec]: start again as before (a restart after lock); [cli]:
/// the program (an app's "Connect" in "Detected on this computer"); [newAgent]: a new agent is chosen (the Check
/// panel: a program refused because another one holds the agent's token gets an agent of its own).
Future<void> showStartAgentDialog(BuildContext context,
        {String? agent, AgentRunSpec? spec, AgentCli? cli, bool newAgent = false}) =>
    showXDialog<void>(
        context, (_) => StartAgentDialog(agent: newAgent ? _newAgent : agent ?? spec?.agent, spec: spec, cli: cli),
        dismissible: false);

const _newAgent = '\u0000new';

class StartAgentDialog extends StatefulWidget {
  const StartAgentDialog({super.key, this.agent, this.spec, this.cli});
  final String? agent;
  final AgentRunSpec? spec;
  final AgentCli? cli;

  @override
  State<StartAgentDialog> createState() => _StartAgentDialogState();
}

class _StartAgentDialogState extends State<StartAgentDialog> {
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _folder = TextEditingController();
  final _auth = OwnerAuthController();
  final _setup = AgentSetupController();
  String? _agent;
  AgentCli _cli = AgentCli.claude;
  int? _label;

  /// The six data labels instead of the two roles.
  bool _otherLabel = false;
  bool _allLinks = true;

  /// v6: a new agent also reads messages to everyone (off by default).
  bool _everyone = false;
  final Set<String> _links = {};
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final m = AppScope.read(context);
    _agent = widget.agent ?? (m.startableAgents.isEmpty ? _newAgent : m.startableAgents.first.name);
    // The role the owner chose for new agents (none chosen: nothing preselected, Q-15).
    _label = AppearanceScope.read(context)?.rolePreset?.level;
    _load(_agent!);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final m = AppScope.read(context);
      // The CLI may be only in the login shell's PATH (read once per window session): show it once it is known.
      if (m.agentHost case final host?) {
        unawaited(host.loadLoginShell().then((more) {
          if (more && mounted) setState(() {});
        }));
      }
      await Future.wait([m.refreshAgents(), m.refreshWake()]);
      if (!mounted) return;
      final agents = m.startableAgents;
      // The list was not loaded yet (or the agent is gone): pick the first agent, unless the owner already started
      // filling in a new one.
      final stale = _agent == _newAgent
          ? widget.agent == null && agents.isNotEmpty && _name.text.isEmpty
          : !agents.any((a) => a.name == _agent);
      if (stale) {
        setState(() {
          _agent = agents.isEmpty ? _newAgent : agents.first.name;
          _load(_agent!);
        });
      }
    });
  }

  /// The last start of [agent] (or the explicit [StartAgentDialog.spec]); otherwise Claude Code, folder left blank
  /// (the hint below shows this agent's own folder — never the home folder by default, D-UI-… TROUBLESHOOTING "macOS
  /// asks Antenna for Documents, Photos, Music…"). A folder remembered from before this fix, when the home folder
  /// was the only default, migrates the same way: it reads as "nothing chosen yet", not as a deliberate pick.
  void _load(String agent) {
    final m = AppScope.read(context);
    final look = AppearanceScope.read(context);
    final home = m.agentHost?.home;
    final s = widget.spec?.agent == agent
        ? widget.spec
        : (agent == _newAgent ? null : AgentRunSpec.fromJson(agent, look?.agentRun(agent)));
    _cli = widget.cli ?? s?.cli ?? AgentCli.claude;
    _command.text = s?.command ?? '';
    final saved = s?.workDir;
    final noFolderSet = saved == null || saved.isEmpty || (home != null && saved == home);
    _folder.text = noFolderSet ? '' : saved;
  }

  /// This agent's own folder, shown as the folder field's hint while it is blank (so it is never a silent default
  /// the owner cannot see): blank for a brand new agent with no name yet.
  String _folderHint(AgentHost? host) {
    if (host == null) return '/';
    final name = _agentName;
    return name.isEmpty ? host.home : host.ownFolder(name);
  }

  /// The folder the setup is for: the one chosen, or this agent's own ('' while a new agent has no name).
  String _setupDir(AgentHost host) {
    final chosen = _folder.text.trim();
    if (chosen.isNotEmpty) return chosen;
    return _agentName.isEmpty ? '' : host.ownFolder(_agentName);
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _folder.dispose();
    _auth.dispose();
    _setup.dispose();
    super.dispose();
  }

  bool get _creating => _agent == _newAgent;

  String get _agentName => _creating ? _name.text.trim() : (_agent ?? '');

  /// Claude Code and Codex read instruction files from their folder; an own command gets no setup.
  bool get _setsUp => _cli != AgentCli.custom;

  /// A password is needed unless this window already holds the agent's token.
  bool get _needsPassword => _creating || !AppScope.read(context).hasAgentToken(_agentName, cli: _cli);

  String? get _formProblem {
    final l = context.l;
    if (_creating) {
      final n = _name.text.trim();
      if (n.isEmpty) return l.agentErrName;
      if (!RegExp(r'^[A-Za-z0-9._-]{1,40}$').hasMatch(n)) return l.agentErrNameChars;
      if (_label == null) return l.agentErrLabel;
      if (!_allLinks && _links.isEmpty) return l.agentErrLinks;
    }
    if (_cli == AgentCli.custom && _command.text.trim().isEmpty) return l.codeErrBadCommand;
    if (_setsUp && _setup.gitIncomplete) return l.setupErrGitIdentity;
    return null;
  }

  Future<void> _pickFolder() async {
    final p = await FolderChooser.instance.pick(context.l.codeChooseFolder);
    if (p != null && mounted) setState(() => _folder.text = p);
  }

  Future<void> _start() async {
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
    final look = AppearanceScope.read(context);
    final host = m.agentHost;
    // What the owner ticked in "Set up this folder", before anything else: a refusal starts nothing.
    if (_setsUp && host != null) {
      try {
        await _setup.apply();
      } on AgentSetupException catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = e;
        });
        return;
      }
      if (!mounted) return;
    }
    var folder = _folder.text.trim();
    if (folder.isEmpty && host != null) {
      // Nothing chosen: this agent's own folder, created now (never for an agent that is not actually starting).
      folder = host.ownFolder(_agentName);
      try {
        host.prepareOwnFolder(_agentName);
      } on FileSystemException catch (e) {
        setState(() {
          _busy = false;
          _error = e;
        });
        return;
      }
    }
    final spec = AgentRunSpec(
      agent: _agentName,
      cli: _cli,
      workDir: folder,
      command: _cli == AgentCli.custom ? _command.text.trim() : '',
    );
    final err = await m.startAgent(
      spec,
      auth: _needsPassword ? _auth.auth(m, context.l.touchIdReasonStartAgent(cutForPrompt(spec.agent))) : null,
      create: _creating
          ? NewAgent(
              name: spec.agent,
              localLevel: _label!,
              links: _allLinks ? null : _links.toList(),
              everyone: _everyone,
            )
          : null,
    );
    _auth.password.clear();
    if (!mounted) return;
    if (err == null) {
      look?.rememberAgentRun(spec.agent, spec.toJson());
      // The terminal lives in Code mode: a start from Chat mode ("Connect") switches to it.
      if (look != null && look.ui != InterfaceMode.code) look.ui = InterfaceMode.code;
      Navigator.pop(context);
      return;
    }
    final fellBack = _auth.fellBack(context.l, m, err);
    setState(() {
      _busy = false;
      _error = fellBack ? null : err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return XDialogShell(
      title: l.codeStartTitle,
      icon: Icons.terminal_rounded,
      subtitle: l.codeStartAbout,
      width: 640,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton.icon(
          key: const Key('code-start-go'),
          onPressed: _busy ? null : _start,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: Text(l.codeStart),
        ),
      ],
      child: _form(context),
    );
  }

  Widget _form(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final host = m.agentHost;
    final busy = _creating ? null : m.busyElsewhere(_agentName);
    final found = host?.locate(_cli);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(l.codeAgentLabel),
      DropdownButton<String>(
        key: const Key('code-agent'),
        value: _agent,
        isExpanded: true,
        underline: Container(height: 1, color: XColors.lineStrong),
        items: [
          for (final a in m.startableAgents)
            DropdownMenuItem(
              value: a.name,
              child: Row(children: [
                XAvatar(a.name,
                    size: 24, agent: true, brand: knownAgentBrand(m, a.name), picture: m.pictureOfMine(agent: a.name)),
                const SizedBox(width: 8),
                Text(a.name, style: XText.body),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      if (a.localLevel != null) l.agentRowLabel(a.localLevel!),
                      a.links == null ? l.agentAllLinks : l.agentRowLinks(a.links!.join(', ')),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: XText.monoSmall,
                  ),
                ),
              ]),
            ),
          DropdownMenuItem(
            value: _newAgent,
            child: Row(children: [
              Icon(Icons.add_rounded, size: 18, color: XColors.accent),
              const SizedBox(width: 8),
              Text(l.codeNewAgent, style: XText.body.copyWith(color: XColors.accent)),
            ]),
          ),
        ],
        onChanged: (v) => setState(() {
          _agent = v;
          _error = null;
          if (v != null) _load(v);
        }),
      ),
      if (busy != null) ...[
        const SizedBox(height: 8),
        Text(l.codeAgentBusy(busy),
            key: const Key('code-agent-busy'), style: XText.bodyDim.copyWith(color: XColors.warn, fontSize: 12)),
      ],
      if (_creating) ..._newAgentFields(context),
      const SizedBox(height: 16),
      SectionLabel(l.codeProgram),
      SegmentedButton<AgentCli>(
        key: const Key('code-program'),
        showSelectedIcon: false,
        // The same look as the segmented choices in Settings.
        style: SegmentedButton.styleFrom(
          textStyle: XText.label,
          side: BorderSide(color: XColors.lineStrong),
          selectedBackgroundColor: XColors.accentSoft,
          selectedForegroundColor: XColors.accent,
          foregroundColor: XColors.textDim,
        ),
        segments: [
          ButtonSegment(value: AgentCli.claude, label: Text('Claude Code', key: const Key('code-cli-claude'))),
          ButtonSegment(value: AgentCli.codex, label: Text('Codex', key: const Key('code-cli-codex'))),
          ButtonSegment(value: AgentCli.custom, label: Text(l.codeProgramCustom, key: const Key('code-cli-custom'))),
        ],
        selected: {_cli},
        onSelectionChanged: (s) => setState(() {
          _cli = s.first;
          _error = null;
        }),
      ),
      const SizedBox(height: 8),
      if (_cli == AgentCli.custom)
        TextField(
          key: const Key('code-command'),
          controller: _command,
          style: XText.body.copyWith(fontFamily: XFonts.mono),
          decoration: InputDecoration(labelText: l.codeCommand, hintText: l.codeCommandHint),
        )
      else if (found != null)
        Text(l.codeProgramFound(found), key: const Key('code-program-found'), style: XText.monoSmall)
      else
        Text(
          l.codeProgramMissing(_cli.binary),
          key: const Key('code-program-missing'),
          style: XText.bodyDim.copyWith(color: XColors.warn, fontSize: 12),
        ),
      const SizedBox(height: 16),
      SectionLabel(l.codeFolder),
      Row(children: [
        Expanded(
          child: TextField(
            key: const Key('code-folder'),
            controller: _folder,
            style: XText.body.copyWith(fontFamily: XFonts.mono, fontSize: 12),
            decoration: InputDecoration(hintText: _folderHint(host)),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const Key('code-folder-pick'),
          onPressed: _pickFolder,
          icon: const Icon(Icons.folder_open_outlined, size: 16),
          label: Text(l.codeChooseFolder),
        ),
      ]),
      // Chosen, not merely left blank: the owner picked the home folder itself, so macOS will attribute the coding
      // tool's scan of it to Antenna (TROUBLESHOOTING "macOS asks Antenna for Documents, Photos, Music…").
      if (host != null && _folder.text.trim() == host.home) ...[
        const SizedBox(height: 8),
        Row(
          key: const Key('code-folder-home-warning'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: XColors.warn),
            const SizedBox(width: 8),
            Expanded(child: Text(l.codeFolderHomeWarning, style: XText.meta.copyWith(color: XColors.warn))),
          ],
        ),
      ],
      if (host != null && _setsUp) ...[
        const SizedBox(height: 12),
        AgentSetupSection(
          controller: _setup,
          host: host,
          dir: _setupDir(host),
          own: _folder.text.trim().isEmpty,
          agent: _agentName,
          claudeCode: _cli == AgentCli.claude,
        ),
      ],
      const SizedBox(height: 16),
      if (_needsPassword) ...[
        // An existing agent gets a new token (`agent_token`): say what that means for its other configs.
        if (!_creating) ...[
          Text(l.codeNewTokenNote, key: const Key('code-new-token'), style: XText.meta),
          const SizedBox(height: 8),
        ],
        OwnerAuthField(controller: _auth, onSubmitted: (_) => _start()),
      ] else
        Text(l.codeNoPasswordNeeded, key: const Key('code-no-password'), style: XText.bodyDim),
      if (_error != null)
        _error is String
            ? ErrorLine(_error! as String)
            : ErrorLine(describeCodeError(l, _error!)),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.m)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.key_off_outlined, size: 17, color: XColors.textDim),
          const SizedBox(width: 8),
          Expanded(child: Text(l.codeTokenNote, style: XText.meta.copyWith(color: XColors.textDim, height: 1.45))),
        ]),
      ),
    ]);
  }

  List<Widget> _newAgentFields(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    return [
      const SizedBox(height: 12),
      TextField(
        key: const Key('agent-name'),
        controller: _name,
        autofocus: true,
        style: XText.body.copyWith(fontFamily: XFonts.mono),
        decoration: InputDecoration(labelText: l.agentName, hintText: 'jarvis'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Text(l.codeRole, style: XText.label),
        const SizedBox(width: 8),
        Expanded(child: Text(l.agentDataLabelHint, style: XText.monoSmall)),
      ]),
      const SizedBox(height: 4),
      if (!_otherLabel) ...[
        RolePresetChoice(
          value: RolePreset.values.where((r) => r.level == _label).firstOrNull,
          onChanged: (r) => setState(() => _label = r.level),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('code-other-label'),
            onPressed: () => setState(() => _otherLabel = true),
            child: Text(l.rolePresetOther),
          ),
        ),
      ] else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final d in DataLabel.all)
            DataLabelCard(d, selected: _label == d.level, onTap: () => setState(() => _label = d.level)),
        ]),
      const SizedBox(height: 12),
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
    ];
  }
}
