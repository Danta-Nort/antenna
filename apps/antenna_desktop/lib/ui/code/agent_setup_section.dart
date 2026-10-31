// SPDX-License-Identifier: AGPL-3.0-only
// Start an agent → "Set up this folder" (D-124, state/agent_setup.dart): the agent's instruction files, the folder's
// git identity and Claude Code's permission rules there, chosen by the owner, shown exactly before anything is
// written, and done once, when Start is pressed. Compact by default: one line says what Start will do.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_setup.dart';
import '../../state/code_mode.dart';
import '../../theme/x_theme.dart';
import '../agents/connect_widgets.dart' show CodeBlock;
import 'code_text.dart';

/// What the owner chose for the folder and what the folder has; the dialog applies it on Start.
class AgentSetupController extends ChangeNotifier {
  final gitName = TextEditingController();
  final gitEmail = TextEditingController();

  /// `null` until the owner touches it: then it follows the folder (ticked while the agent's own folder has no
  /// `AGENTS.md`; a project folder the owner chose gets nothing unless the owner ticks it).
  bool? _instructions;
  bool _git = false;

  /// The ids of [agentSetupRules] the owner ticked; `null` until the owner touches one: then Antenna's own tools in
  /// the agent's own folder, nothing in a project folder the owner chose (its repository is the owner's).
  Set<String>? _allow;

  /// The ids of [agentSetupRules] ticked now.
  Set<String> get allow => _allow ?? (_own ? const {'antenna-tools'} : const {});
  bool _open = false;
  bool _preview = false;

  AgentHost? _host;
  String _dir = '';
  bool _own = false;
  String _agent = '';
  bool _claudeCode = true;

  /// What the folder has (`null` while it is read, or for no folder).
  AgentFolderState? state;
  int _gen = 0;
  bool _disposed = false;

  bool get open => _open;
  bool get preview => _preview;
  bool get git => _git;
  bool get instructions => _instructions ?? (_own && !(_current?.hasAgentsMd ?? false));
  bool get claudeCode => _claudeCode;
  bool get hasAgent => _agent.isNotEmpty;

  void toggleOpen() => _set(() => _open = !_open);
  void togglePreview() => _set(() => _preview = !_preview);
  set instructions(bool v) => _set(() => _instructions = v);
  set git(bool v) => _set(() => _git = v);
  void rule(String id, bool on) => _set(() {
        final a = _allow ??= {...allow};
        on ? a.add(id) : a.remove(id);
      });
  void edited() => _set(() {});

  void _set(void Function() f) {
    f();
    if (!_disposed) notifyListeners();
  }

  /// The state read for the folder now targeted (a read for an earlier folder does not count).
  AgentFolderState? get _current => state != null && state!.dir == _dir ? state : null;

  /// The folder, the agent and the program as the dialog has them now; the folder is read again when it changes.
  void target(AgentHost host,
      {required String dir, required bool own, required String agent, required bool claudeCode}) {
    _agent = agent;
    _claudeCode = claudeCode;
    if (identical(host, _host) && dir == _dir && own == _own) return;
    _host = host;
    _dir = dir;
    _own = own;
    unawaited(_inspect());
  }

  Future<void> _inspect() async {
    final gen = ++_gen;
    final host = _host;
    if (host == null || _dir.isEmpty) return;
    final s = await inspectAgentFolder(host.folders, host.folderGit, _dir, own: _own);
    if (gen != _gen || _disposed) return;
    state = s;
    notifyListeners();
  }

  /// Git is ticked without a name or an email.
  bool get gitIncomplete => _git && (gitName.text.trim().isEmpty || gitEmail.text.trim().isEmpty);

  AgentSetupChoice get choice => AgentSetupChoice(
        instructions: instructions,
        gitName: _git && !gitIncomplete ? gitName.text.trim() : null,
        gitEmail: _git && !gitIncomplete ? gitEmail.text.trim() : null,
        allow: _claudeCode ? {...allow} : const {},
      );

  /// The plan for the folder as it is now, or why there is none; (`null`, `null`) while the folder is read or before
  /// the agent has a name (its instructions carry it).
  (AgentSetupPlan?, AgentSetupException?) get plan {
    final s = _current;
    if (s == null || _agent.isEmpty) return (null, null);
    try {
      return (planAgentSetup(s, agent: _agent, claudeCode: _claudeCode, choice: choice), null);
    } on AgentSetupException catch (e) {
      return (null, e);
    }
  }

  /// Everything is in place: the instruction files are there and nothing ticked would change anything.
  bool get inPlace {
    final s = _current;
    final (p, _) = plan;
    return s != null && p != null && p.nothingToDo && s.hasAgentsMd && (!_claudeCode || s.hasClaudeMd);
  }

  /// Start: the plan made again from the folder as it is now (nothing that appeared there since is overwritten), then
  /// done in order. Throws [AgentSetupException]; nothing ticked: nothing done.
  Future<void> apply() async {
    final host = _host;
    if (host == null || _dir.isEmpty || !choice.any) return;
    final s = await inspectAgentFolder(host.folders, host.folderGit, _dir, own: _own);
    final p = planAgentSetup(s, agent: _agent, claudeCode: _claudeCode, choice: choice);
    await applyAgentSetup(p, host.folders, host.folderGit);
    await _inspect();
  }

  @override
  void dispose() {
    _disposed = true;
    gitName.dispose();
    gitEmail.dispose();
    super.dispose();
  }
}

/// The plan exactly as it will be done, for the owner to read before Start (the same lines as `antenna agent setup`).
String setupPreviewText(AppLocalizations l, AgentSetupPlan p) {
  final b = StringBuffer()..writeln(l.setupStepHead(p.dir));
  if (p.steps.isEmpty) b.writeln('  ${l.setupStepNone}');
  void quote(String content) {
    final lines = content.split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    for (final line in lines) {
      b.writeln('    | $line');
    }
  }

  for (final st in p.steps) {
    switch (st) {
      case CreateFolderStep(:final path):
        b.writeln('  ${l.setupStepFolder(path)}');
      case KeepFileStep(:final path):
        b.writeln('  ${l.setupStepKeep(path)}');
      case WriteFileStep(:final path, :final content):
        b.writeln('  ${l.setupStepWrite(path)}');
        quote(content);
      case RunStep(:final dir, :final argv):
        b.writeln('  ${l.setupStepRun(dir, setupCommandLine(argv))}');
      case SettingsStep(:final path, :final added, :final backup, :final content):
        b.writeln('  ${l.setupStepRules(path, added.join(', '))}');
        if (backup != null) b.writeln('    ${l.setupStepBackup(backup)}');
        b.writeln('    ${l.setupStepResult}');
        quote(content);
    }
  }
  return b.toString().trimRight();
}

/// What Start will do, in one line.
String _summary(AppLocalizations l, AgentSetupPlan p) {
  final parts = <String>[];
  var git = false;
  for (final st in p.steps) {
    switch (st) {
      case CreateFolderStep():
        parts.add(l.setupDoFolder);
      case WriteFileStep(:final path):
        parts.add(l.setupDoWrite(path.substring(path.lastIndexOf('/') + 1)));
      case RunStep() when !git:
        git = true;
        parts.add(l.setupDoGit);
      case SettingsStep(:final added):
        parts.add(l.setupDoRules(added.length));
      case RunStep() || KeepFileStep():
        break;
    }
  }
  return l.setupWillDo(parts.join(', '));
}

String _ruleLabel(AppLocalizations l, String id) => switch (id) {
      'antenna-tools' => l.setupRuleTools,
      'antenna-cli' => l.setupRuleCli,
      'git' => l.setupRuleGit,
      _ => id,
    };

/// The section under the folder field.
class AgentSetupSection extends StatefulWidget {
  const AgentSetupSection({
    super.key,
    required this.controller,
    required this.host,
    required this.dir,
    required this.own,
    required this.agent,
    required this.claudeCode,
  });

  final AgentSetupController controller;
  final AgentHost host;

  /// The working folder ('' when there is none yet: a new agent without a name and no folder chosen).
  final String dir;

  /// [dir] is the agent's own folder, made when missing.
  final bool own;
  final String agent;
  final bool claudeCode;

  @override
  State<AgentSetupSection> createState() => _AgentSetupSectionState();
}

class _AgentSetupSectionState extends State<AgentSetupSection> {
  @override
  void initState() {
    super.initState();
    _target();
  }

  @override
  void didUpdateWidget(AgentSetupSection old) {
    super.didUpdateWidget(old);
    _target();
  }

  void _target() => widget.controller
      .target(widget.host, dir: widget.dir, own: widget.own, agent: widget.agent, claudeCode: widget.claudeCode);

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: widget.controller, builder: (context, _) => _body());

  Widget _body() {
    final l = context.l;
    final c = widget.controller;
    final (plan, error) = c.plan;
    final inPlace = c.inPlace;
    final String? summary = !c.hasAgent
        ? l.setupNeedsName
        : error != null
            ? describeSetupError(l, error)
            : plan == null
                ? null
                : inPlace
                    ? l.setupInPlace
                    : plan.nothingToDo
                        ? l.setupNothing
                        : _summary(l, plan);
    return Container(
      key: const Key('setup'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(color: XColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          key: const Key('setup-toggle'),
          borderRadius: BorderRadius.circular(XRadius.m),
          onTap: c.toggleOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(inPlace ? Icons.check_circle_outline_rounded : Icons.tune_rounded,
                  size: 17, color: inPlace ? XColors.ok : XColors.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.setupTitle, style: XText.label.copyWith(color: XColors.text)),
                  if (summary != null)
                    Text(summary,
                        key: const Key('setup-summary'),
                        style: XText.meta.copyWith(color: error != null ? XColors.warn : XColors.textDim)),
                ]),
              ),
              Icon(c.open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: XColors.textDim),
            ]),
          ),
        ),
        if (c.open) ...[
          const SizedBox(height: 4),
          _Check(
            k: const Key('setup-instructions'),
            value: c.instructions,
            label: l.setupInstructions,
            hint: l.setupInstructionsHint(c.claudeCode ? 'AGENTS.md, CLAUDE.md' : 'AGENTS.md'),
            onChanged: (v) => c.instructions = v,
          ),
          _Check(
            k: const Key('setup-git'),
            value: c.git,
            label: l.setupGit,
            hint: l.setupGitHint,
            onChanged: (v) => c.git = v,
          ),
          if (c.git)
            Padding(
              padding: const EdgeInsets.only(left: 32, right: 8, bottom: 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    key: const Key('setup-git-name'),
                    controller: c.gitName,
                    style: XText.body,
                    decoration: InputDecoration(labelText: l.setupGitName, hintText: 'Robin Example'),
                    onChanged: (_) => c.edited(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const Key('setup-git-email'),
                    controller: c.gitEmail,
                    style: XText.body,
                    decoration: InputDecoration(labelText: l.setupGitEmail, hintText: 'robin@example.com'),
                    onChanged: (_) => c.edited(),
                  ),
                ),
              ]),
            ),
          if (c.claudeCode) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Text(l.setupPermissions, style: XText.label.copyWith(color: XColors.text)),
            ),
            Text(l.setupPermissionsHint, style: XText.meta),
            for (final (id, rule) in agentSetupRules)
              _Check(
                k: Key('setup-rule-$id'),
                value: c.allow.contains(id),
                label: _ruleLabel(l, id),
                hint: rule,
                mono: true,
                onChanged: (v) => c.rule(id, v),
              ),
          ],
          if (plan != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('setup-preview-toggle'),
                onPressed: c.togglePreview,
                icon: Icon(c.preview ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                label: Text(c.preview ? l.setupPreviewHide : l.setupPreviewShow),
              ),
            ),
            if (c.preview)
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: SingleChildScrollView(
                    child: CodeBlock(setupPreviewText(l, plan), key: const Key('setup-preview')),
                  ),
                ),
              ),
          ],
        ],
      ]),
    );
  }
}

/// A checkbox with its label and a hint under it.
class _Check extends StatelessWidget {
  const _Check({
    required this.k,
    required this.value,
    required this.label,
    required this.onChanged,
    this.hint,
    this.mono = false,
  });
  final Key k;
  final bool value;
  final String label;
  final String? hint;

  /// The hint is a rule or a file name, shown as written.
  final bool mono;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(XRadius.m),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(key: k, value: value, onChanged: (v) => onChanged(v ?? false)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(label, style: XText.body.copyWith(color: XColors.text)),
                ),
                if (hint != null) Text(hint!, style: mono ? XText.monoSmall : XText.meta),
              ]),
            ),
          ]),
        ),
      );
}
