// SPDX-License-Identifier: AGPL-3.0-only
// New team (D-111, DESIGN "Teams"): the name, the project folder (a git repository of this computer), the lead (an
// agent of this computer, a local model, or the owner in person), the budget of workers (up to N of a kind for a
// role), the rules (commands, the check commands tasks may name, the registries checks may reach, who applies to the
// project's branch, local only, limits), and the machines (this computer; other computers of the owner lend with My
// devices, later). One password: the budget lets the lead create agents (`team_create`). The daemon validates
// everything again; the form only spares the owner a round trip.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/messages.dart';
import '../../state/teams.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../code/start_agent_dialog.dart' show FolderChooser;
import '../security/owner_confirm.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/popover.dart';
import 'team_dialogs.dart' show parseCheckCommand;
import 'team_widgets.dart';

Future<void> showNewTeamDialog(BuildContext context) =>
    showXDialog<void>(context, (_) => const NewTeamDialog(), dismissible: false);

/// The size class of a local model from its parameter count (`2.27B`, `9B`): S below 5B, M below 20B, L above, as
/// the daemon's `rules::class_of` (D-111 item 6). `null` when the count does not read.
String? modelClass(String params) {
  final m = RegExp(r'([\d.]+)\s*[Bb]').firstMatch(params);
  final b = m == null ? null : double.tryParse(m.group(1)!);
  if (b == null) return null;
  return b < 5 ? 'S' : (b < 20 ? 'M' : 'L');
}

/// The roles a local model of [cls] takes (D-111 item 6: no local class codes while local agents have no tools). The
/// daemon decides; this only keeps the form from offering what it would refuse.
List<String> localRoles(String? cls) => switch (cls) {
      'S' => const ['triage', 'summaries'],
      'M' || 'L' => const ['triage', 'summaries', 'docs', 'drafts', 'translation'],
      _ => const [],
    };

/// One line of the budget being written.
class SlotDraft {
  SlotDraft({this.role = 'coder', this.kind = WorkerKind.claude, this.max = 2, String command = 'claude', this.model})
      : command = TextEditingController(text: command);
  String role;
  String kind;
  int max;

  /// `claude`, `program`: the command line.
  final TextEditingController command;

  /// `local`: the catalog model.
  String? model;

  TeamSlot? toSlot() {
    final argv = kind == WorkerKind.local ? const <String>[] : (parseCheckCommand(command.text) ?? const <String>[]);
    if (kind == WorkerKind.program && argv.isEmpty) return null;
    if (kind == WorkerKind.local && model == null) return null;
    return TeamSlot(
      role: role,
      kind: kind,
      max: max,
      model: kind == WorkerKind.local ? model : null,
      argv: kind == WorkerKind.claude && argv.length == 1 && argv.first == 'claude' ? const [] : argv,
    );
  }
}

class NewTeamDialog extends StatefulWidget {
  const NewTeamDialog({super.key});

  @override
  State<NewTeamDialog> createState() => _NewTeamDialogState();
}

class _NewTeamDialogState extends State<NewTeamDialog> {
  final _name = TextEditingController();
  final _project = TextEditingController();
  final _target = TextEditingController();
  final _check = TextEditingController();
  final _host = TextEditingController();
  final _path = TextEditingController();
  final _env = TextEditingController();
  final _turnMin = TextEditingController(text: '30');
  final _checkMin = TextEditingController(text: '10');
  final _tokens = TextEditingController(text: '0');
  final _retries = TextEditingController(text: '3');
  final _maxWorkers = TextEditingController();

  /// The lead: an agent's name, or [_me] for the owner in person.
  String _lead = _me;
  static const _me = '\u0000me';
  bool _leadChosen = false;
  final List<SlotDraft> _slots = [SlotDraft()];
  bool _commands = true;
  final List<List<String>> _checks = [];
  final List<String> _hosts = [];
  final List<String> _paths = [];
  final List<String> _envs = [];
  bool _ownerApplies = true;
  bool _localOnly = false;
  bool _limits = false;
  Object? _error;
  String? _invalid;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The agents that may lead come from the daemon's list, read now (it may not have been read in this session).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final m = AppScope.read(context);
      await m.refreshAgents();
      if (!mounted || _leadChosen) return;
      // The first agent running in Code mode here leads by default (the one the owner works with), else the first agent.
      final leads = _leads();
      setState(() => _lead = (leads.where((a) => m.runOf(a.name)?.alive ?? false).firstOrNull ?? leads.firstOrNull)?.name ?? _me);
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _project, _target, _check, _host, _path, _env, _turnMin, _checkMin, _tokens, _retries, _maxWorkers,
        for (final s in _slots) s.command]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Agents that can lead: this node's agents that are no team's worker and lead no other team, and not a link's wake
  /// agent (it runs only in the daemon's sandbox).
  List<AgentInfo> _leads() {
    final m = AppScope.read(context);
    final workers = {for (final t in m.teamDetails.values) for (final w in t.workers) w.name};
    final leading = {for (final t in m.teams) ?t.lead};
    return [
      for (final a in m.agents)
        if (!workers.contains(a.name) && !leading.contains(a.name) && !m.isWakeAgent(a.name)) a,
    ];
  }

  Future<void> _pickFolder() async {
    final p = await FolderChooser.instance.pick(context.l.teamNewChooseFolder);
    if (p != null && mounted) setState(() => _project.text = p);
  }

  /// What is wrong with the form, in words; `null` when it can go to the daemon.
  String? _validate(AppLocalizations l, List<LocalModelInfo> models) {
    if (!validTeamName(_name.text.trim())) return l.teamNewBadName;
    final p = _project.text.trim();
    if (p.isEmpty || !p.startsWith('/')) return l.teamNewBadProject;
    if (_slots.isEmpty) return l.teamNewNoSlots;
    for (final s in _slots) {
      if (s.kind == WorkerKind.program && (parseCheckCommand(s.command.text) ?? const []).isEmpty) return l.teamNewProgramCommand;
      if (s.kind == WorkerKind.local && s.model == null) return l.teamNewLocalModel;
      if (_localOnly && s.kind != WorkerKind.local) return l.teamNewLocalOnlySlots;
    }
    if (_localOnly && _lead != _me) {
      final a = AppScope.read(context).agents.where((x) => x.name == _lead).firstOrNull;
      if (a?.localModel == null) return l.teamNewLocalOnlyLead;
    }
    return null;
  }

  TeamTemplate _template() => TeamTemplate(
        commands: _commands,
        checks: _checks,
        checkHosts: _hosts,
        checkPaths: _paths,
        checkEnv: _envs,
        turnTimeoutSecs: (int.tryParse(_turnMin.text.trim()) ?? 30) * 60,
        checkTimeoutSecs: (int.tryParse(_checkMin.text.trim()) ?? 10) * 60,
        maxTaskTokens: int.tryParse(_tokens.text.trim()) ?? 0,
        checkRetries: int.tryParse(_retries.text.trim()) ?? 3,
        apply: _ownerApplies ? 'owner' : 'lead',
        localOnly: _localOnly,
      );

  Future<void> _create() async {
    final m = AppScope.read(context);
    final l = context.l;
    final bad = _validate(l, m.localModels);
    setState(() {
      _invalid = bad;
      _error = null;
    });
    if (bad != null) return;
    final name = _name.text.trim();
    TeamInfo? team;
    setState(() => _busy = true);
    final (done, err) = await confirmOwner(context,
        action: l.teamNewAction(name),
        detail: l.teamNewPasswordDetail,
        cli: 'antenna team create $name --project ${_project.text.trim()}', run: (auth) async {
      final (t, e) = await m.createTeam(
          auth,
          (pw) => TeamCreateRequest(
                name: name,
                project: _project.text.trim(),
                lead: _lead == _me ? null : _lead,
                slots: [for (final s in _slots) ?s.toSlot()],
                maxWorkers: int.tryParse(_maxWorkers.text.trim()),
                template: _template(),
                target: _target.text.trim().isEmpty ? null : _target.text.trim(),
                password: pw,
              ));
      team = t;
      return e;
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (team case final made?) {
      Navigator.pop(context);
      m.openBoard(made.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final leads = _leads();
    final mac = m.agentHost?.macos ?? defaultTargetPlatform == TargetPlatform.macOS;
    final ownComputers = [for (final c in m.contacts) if (c.trust >= 5) c];
    return XDialogShell(
      key: const Key('team-new-dialog'),
      title: l.teamNewTitle,
      titleTag: const ExperimentalTag(),
      icon: Icons.groups_2_outlined,
      width: 720,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton.icon(
          key: const Key('team-new-create'),
          onPressed: _busy ? null : _create,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_rounded, size: 16),
          label: Text(l.teamNewCreate),
        ),
      ],
      // The list tiles paint on the nearest Material: the dialog's panel is a decorated box.
      child: Material(
        type: MaterialType.transparency,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.teamNewAbout, key: const Key('team-new-about'), style: XText.bodyDim),
        const SizedBox(height: 16),
        _section(l.teamNewSectionProject),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 240,
            child: TextField(
              key: const Key('team-new-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: l.teamNewName, helperText: l.teamNewNameHelp, helperMaxLines: 3),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const Key('team-new-project'),
              controller: _project,
              style: XText.monoStrong,
              decoration: InputDecoration(
                labelText: l.teamNewProject,
                helperText: mac ? l.teamNewProjectHelpMac : l.teamNewProjectHelp,
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  key: const Key('team-new-choose'),
                  tooltip: l.teamNewChooseFolder,
                  onPressed: _pickFolder,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          key: const Key('team-new-target'),
          controller: _target,
          decoration: InputDecoration(labelText: l.teamNewTarget, hintText: l.teamNewTargetHint),
        ),
        const SizedBox(height: 20),
        _section(l.teamNewSectionLead),
        RadioGroup<String>(
          groupValue: _lead,
          onChanged: (v) => setState(() {
            _lead = v ?? _me;
            _leadChosen = true;
          }),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final a in leads)
              RadioListTile<String>(
                key: Key('team-new-lead-${a.name}'),
                value: a.name,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(a.name),
                subtitle: Text(
                  a.localModel != null
                      ? l.teamNewLeadLocal(a.localModel!)
                      : (m.runOf(a.name)?.alive ?? false)
                          ? l.teamNewLeadCodeMode
                          : l.teamNewLeadAgent,
                  style: XText.meta,
                ),
              ),
            RadioListTile<String>(
              key: const Key('team-new-lead-me'),
              value: _me,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(l.teamNewLeadMe),
              subtitle: Text(l.teamNewLeadMeHelp, style: XText.meta),
            ),
          ]),
        ),
        if (leads.isEmpty) Text(l.teamNewNoAgents, style: XText.meta),
        const SizedBox(height: 20),
        _section(l.teamNewSectionWorkers, help: l.teamNewWorkersHelp, id: 'team-workers'),
        for (var i = 0; i < _slots.length; i++) _slotRow(context, i, m.localModels),
        Row(children: [
          TextButton.icon(
            key: const Key('team-new-add-slot'),
            onPressed: () => setState(() => _slots.add(SlotDraft(role: 'tester', max: 1))),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: Text(l.teamNewAddSlot),
          ),
          const Spacer(),
          SizedBox(
            width: 220,
            child: TextField(
              key: const Key('team-new-max'),
              controller: _maxWorkers,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l.teamNewMaxWorkers, hintText: l.teamNewMaxWorkersHint),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _section(l.teamNewSectionRules),
        SwitchListTile(
          key: const Key('team-new-commands'),
          value: _commands,
          contentPadding: EdgeInsets.zero,
          title: Text(l.teamNewCommands),
          subtitle: Text(l.teamNewCommandsHelp, style: XText.meta),
          onChanged: (v) => setState(() => _commands = v),
        ),
        _listField(
          key: 'team-new-check',
          label: l.teamNewChecks,
          help: l.teamNewChecksHelp,
          controller: _check,
          values: [for (final c in _checks) c.join(' ')],
          mono: true,
          onAdd: (s) {
            final argv = parseCheckCommand(s);
            if (argv != null) _checks.add(argv);
          },
          onRemove: (i) => _checks.removeAt(i),
        ),
        _listField(
          key: 'team-new-host',
          label: l.teamNewHosts,
          help: l.teamNewHostsHelp,
          controller: _host,
          values: _hosts,
          mono: true,
          onAdd: (s) => _hosts.add(s.trim().toLowerCase()),
          onRemove: (i) => _hosts.removeAt(i),
        ),
        const SizedBox(height: 8),
        Text(l.teamNewApplyLabel, style: XText.label.copyWith(color: XColors.text)),
        const SizedBox(height: 4),
        SegmentedButton<bool>(
          key: const Key('team-new-apply'),
          segments: [
            ButtonSegment(value: true, label: Text(l.teamNewApplyOwner)),
            ButtonSegment(value: false, label: Text(l.teamNewApplyLead)),
          ],
          selected: {_ownerApplies},
          onSelectionChanged: (s) => setState(() => _ownerApplies = s.first),
        ),
        const SizedBox(height: 4),
        Text(_ownerApplies ? l.teamNewApplyOwnerHelp : l.teamNewApplyLeadHelp, style: XText.meta),
        SwitchListTile(
          key: const Key('team-new-local-only'),
          value: _localOnly,
          contentPadding: EdgeInsets.zero,
          title: Text(l.teamNewLocalOnly),
          subtitle: Text(l.teamNewLocalOnlyHelp, style: XText.meta),
          onChanged: (v) => setState(() => _localOnly = v),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('team-new-limits'),
            onPressed: () => setState(() => _limits = !_limits),
            icon: Icon(_limits ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
            label: Text(l.teamNewLimits),
          ),
        ),
        if (_limits) ...[
          Row(children: [
            Expanded(child: _number('team-new-turn', l.teamNewTurnMinutes, _turnMin)),
            const SizedBox(width: 12),
            Expanded(child: _number('team-new-check-min', l.teamNewCheckMinutes, _checkMin)),
            const SizedBox(width: 12),
            Expanded(child: _number('team-new-tokens', l.teamNewTaskTokens, _tokens)),
            const SizedBox(width: 12),
            Expanded(child: _number('team-new-retries', l.teamNewRetries, _retries)),
          ]),
          const SizedBox(height: 8),
          _listField(
            key: 'team-new-path',
            label: l.teamNewPaths,
            help: l.teamNewPathsHelp,
            controller: _path,
            values: _paths,
            mono: true,
            onAdd: _paths.add,
            onRemove: (i) => _paths.removeAt(i),
          ),
          _listField(
            key: 'team-new-env',
            label: l.teamNewEnv,
            help: l.teamNewEnvHelp,
            controller: _env,
            values: _envs,
            mono: true,
            onAdd: _envs.add,
            onRemove: (i) => _envs.removeAt(i),
          ),
        ],
        const SizedBox(height: 20),
        _section(l.teamNewSectionMachines),
        _machineRow(Icons.computer_rounded, l.teamCapThisComputer, l.teamNewThisComputer, on: true, key: 'team-new-machine-here'),
        for (final c in ownComputers)
          // Whether it lends is that computer's own switch (My devices, D-114): shown as it reports it, not changed here.
          if (m.ownDevices.where((d) => d.contact == c.label).firstOrNull?.status case final s?)
            _machineRow(Icons.devices_other_rounded, c.label, s.lend ? l.teamNewLends : l.teamNewNotLending,
                on: s.lend, key: 'team-new-machine-${c.label}')
          else
            _machineRow(Icons.devices_other_rounded, c.label, l.teamNewLendLater, on: false, key: 'team-new-machine-${c.label}'),
        if (ownComputers.isEmpty) Text(l.teamNewNoOtherComputers, style: XText.meta),
        if (_invalid case final s?) ErrorLine(s),
        if (_error case final e?) ErrorLine(describeTeamError(l, e), detail: errorDetail(e)),
      ]),
      ),
    );
  }

  Widget _section(String title, {String? help, String? id}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Text(title, style: XText.title),
          if (help != null) ...[const SizedBox(width: 8), HelpHint(help, id: id ?? title, label: title)],
        ]),
      );

  Widget _number(String key, String label, TextEditingController c) => TextField(
        key: Key(key),
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
      );

  Widget _machineRow(IconData icon, String name, String note, {required bool on, required String key}) => Padding(
        key: Key(key),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, size: 18, color: XColors.textDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: XText.body),
              Text(note, style: XText.meta),
            ]),
          ),
          // Lending is the lending machine's own switch, at that machine (D-111, My devices): shown, not changed here.
          Switch(value: on, onChanged: null),
        ]),
      );

  Widget _listField({
    required String key,
    required String label,
    required String help,
    required TextEditingController controller,
    required List<String> values,
    required void Function(String) onAdd,
    required void Function(int) onRemove,
    bool mono = false,
  }) {
    void add() {
      final s = controller.text.trim();
      if (s.isEmpty) return;
      setState(() {
        onAdd(s);
        controller.clear();
      });
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: Key(key),
          controller: controller,
          style: mono ? XText.monoStrong : null,
          decoration: InputDecoration(
            labelText: label,
            helperText: help,
            helperMaxLines: 3,
            suffixIcon: IconButton(
              key: Key('$key-add'),
              tooltip: context.l.teamNewAdd,
              onPressed: add,
              icon: const Icon(Icons.add_rounded, size: 18),
            ),
          ),
          onSubmitted: (_) => add(),
        ),
        if (values.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < values.length; i++)
              InputChip(
                key: Key('$key-$i'),
                label: Text(values[i], style: mono ? XText.mono.copyWith(color: XColors.text) : null),
                onDeleted: () => setState(() => onRemove(i)),
              ),
          ]),
        ],
      ]),
    );
  }

  Widget _slotRow(BuildContext context, int i, List<LocalModelInfo> models) {
    final l = context.l;
    final s = _slots[i];
    final ready = [for (final x in models) if (x.ready) x];
    final cls = s.model == null ? null : modelClass(models.where((x) => x.id == s.model).firstOrNull?.params ?? '');
    final roles = s.kind == WorkerKind.local ? localRoles(cls) : teamRoles;
    if (!roles.contains(s.role) && roles.isNotEmpty) s.role = roles.first;
    return Container(
      key: Key('team-new-slot-$i'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: XColors.bg2,
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(color: XColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
            width: 64,
            child: DropdownButton<int>(
              key: Key('team-new-slot-$i-max'),
              value: s.max,
              isExpanded: true,
              style: XText.body,
              items: [for (var n = 1; n <= 8; n++) DropdownMenuItem(value: n, child: Text('$n'))],
              onChanged: (v) => setState(() => s.max = v ?? 1),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String>(
              key: Key('team-new-slot-$i-kind'),
              value: s.kind,
              isExpanded: true,
              style: XText.body,
              items: [
                DropdownMenuItem(value: WorkerKind.claude, child: Text(l.teamKindClaude)),
                DropdownMenuItem(value: WorkerKind.program, child: Text(l.teamKindProgram)),
                DropdownMenuItem(value: WorkerKind.local, enabled: ready.isNotEmpty, child: Text(l.teamKindLocal)),
                DropdownMenuItem(value: WorkerKind.codex, enabled: false, child: Text(l.teamKindCodexLater)),
              ],
              onChanged: (v) => setState(() {
                s.kind = v ?? WorkerKind.claude;
                if (s.kind == WorkerKind.local) {
                  s.model ??= ready.firstOrNull?.id;
                } else if (s.kind == WorkerKind.claude && s.command.text.trim().isEmpty) {
                  s.command.text = 'claude';
                } else if (s.kind == WorkerKind.program && s.command.text.trim() == 'claude') {
                  s.command.clear();
                }
              }),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String>(
              key: Key('team-new-slot-$i-role'),
              value: roles.contains(s.role) ? s.role : null,
              isExpanded: true,
              style: XText.body,
              items: [for (final r in roles) DropdownMenuItem(value: r, child: Text(r))],
              onChanged: (v) => setState(() => s.role = v ?? s.role),
            ),
          ),
          IconButton(
            key: Key('team-new-slot-$i-remove'),
            tooltip: l.teamNewRemoveSlot,
            onPressed: _slots.length > 1 ? () => setState(() => _slots.removeAt(i).command.dispose()) : null,
            icon: const Icon(Icons.close_rounded, size: 16),
          ),
        ]),
        if (s.kind == WorkerKind.local)
          DropdownButton<String>(
            key: Key('team-new-slot-$i-model'),
            value: ready.any((x) => x.id == s.model) ? s.model : null,
            isExpanded: true,
            hint: Text(l.teamNewPickModel),
            items: [
              for (final x in ready)
                DropdownMenuItem(value: x.id, child: Text('${x.name} · ${l.teamNewModelClass(modelClass(x.params) ?? '?')}')),
            ],
            onChanged: (v) => setState(() => s.model = v),
          )
        else
          TextField(
            key: Key('team-new-slot-$i-command'),
            controller: s.command,
            style: XText.monoStrong,
            decoration: InputDecoration(
              isDense: true,
              labelText: s.kind == WorkerKind.program ? l.teamNewProgramField : l.teamNewClaudeField,
              helperText: s.kind == WorkerKind.program ? l.teamNewProgramHelp : l.teamNewClaudeHelp,
              helperMaxLines: 2,
            ),
          ),
        const SizedBox(height: 4),
        Text(
          s.kind == WorkerKind.local ? l.teamNewSlotLocalNote : l.teamNewSlotCloudNote,
          style: XText.meta,
        ),
      ]),
    );
  }
}
