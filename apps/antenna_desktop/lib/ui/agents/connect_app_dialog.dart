// SPDX-License-Identifier: AGPL-3.0-only
// Connect an AI app (docs/CONNECT-APPS.md), in three steps with one password:
// 1. Set up: the app's agent (new: role and contacts; existing: it gets a new token), whose messages it treats as
//    tasks, the owner password. The daemon issues the token and writes it to the agent's token file.
// 2. Review: exactly what will be written and where (or which link opens), then Write. Nothing in the app is touched
//    before this click; the file is backed up first and only Antenna's entry changes.
// 3. Done: what to do now (connect_next_steps.dart: restart or open an app that reads its settings only at start, on
//    the owner's click; then the exact question to ask in it), and the live status, "Waiting" until the app's MCP
//    server calls the daemon, then "Connected".
// Apps without a one-click path get the step-by-step guide instead of step 2, with the token file's path filled in.
// The token itself is never shown, except when an older daemon cannot write a token file; then a warning sits next
// to it with "Revoke and create a new token".

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/agent_snippets.dart' show DataLabel;
import '../../state/ai_apps.dart';
import '../../state/ai_apps_model.dart';
import '../../state/appearance.dart';
import '../../state/code_mode.dart' show NewAgent;
import '../../state/mcp_config.dart';
import '../../state/messages.dart';
import '../../state/trust.dart' show trustGlyph;
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../code/agents_detected.dart' show RolePresetChoice;
import '../security/owner_confirm.dart';
import '../widgets/ai_logo.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/x_buttons.dart';
import 'agents_dialog.dart' show DataLabelCard;
import 'ai_apps_card.dart';
import 'app_guides.dart';
import 'connect_next_steps.dart';
import 'connect_widgets.dart';
import 'everyone_switch.dart';
import 'tasks_from.dart';

Future<void> showConnectAppDialog(BuildContext context, AiAppDef app) =>
    showXDialog<void>(context, (_) => ConnectAppDialog(app: app), dismissible: false);

/// The manual way (the row's menu, and apps without a one-click path): when the app's agent already has a token
/// file, the guide right away with its path filled in; otherwise the set-up step first, then the guide.
Future<void> showAppGuide(BuildContext context, AiAppDef app) =>
    showXDialog<void>(context, (_) => ConnectAppDialog(app: app, guide: true), dismissible: false);

enum _Step { setup, review, guide, done }

class ConnectAppDialog extends StatefulWidget {
  const ConnectAppDialog({super.key, required this.app, this.guide = false});
  final AiAppDef app;
  final bool guide;

  @override
  State<ConnectAppDialog> createState() => _ConnectAppDialogState();
}

class _ConnectAppDialogState extends State<ConnectAppDialog> {
  final _auth = OwnerAuthController();
  _Step _step = _Step.setup;
  int? _label;
  bool _otherLabel = false;
  bool _allLinks = true;
  final Set<String> _links = {};

  /// v6: the new agent also reads messages to everyone (off by default).
  bool _everyone = false;

  /// `null`: the default (contacts at trust level 5); empty: nobody.
  List<String>? _tasks;
  bool _tasksChanged = false;
  bool _editTasks = false;
  Object? _error;
  bool _busy = false;
  AppAgentToken? _issued;
  ConnectPlan? _plan;
  String? _backup;

  AiAppDef get app => widget.app;

  @override
  void initState() {
    super.initState();
    _label = AppearanceScope.read(context)?.rolePreset?.level;
    if (widget.guide) {
      // The agent already has a token file: the guide right away (no new token, no password).
      final a = AppScope.read(context).aiAppRow(app).agent;
      if (a?.tokenFile case final file?) {
        _issued = AppAgentToken(agent: a!.name, token: '', tokenFile: file);
        _plan = GuidePlan(app);
        _step = _Step.guide;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final m = AppScope.read(context);
      m.refreshAgents();
      m.watchAgents();
      _watching = m;
    });
  }

  @override
  void dispose() {
    _auth.dispose();
    _watching?.unwatchAgents();
    super.dispose();
  }

  /// The model whose `agent_list` polling this dialog asked for (kept for [dispose], when the context is gone).
  AiAppsMixin? _watching;

  /// The app's agent exists already (it gets a new token rather than being created).
  AgentInfo? get _existing {
    final m = AppScope.read(context);
    return m.aiAppRow(app).agent ?? m.agents.where((a) => a.name == app.agent).firstOrNull;
  }

  String? get _problem {
    final l = context.l;
    if (_existing == null) {
      if (_label == null) return l.agentErrLabel;
      if (!_allLinks && _links.isEmpty) return l.agentErrLinks;
    }
    return null;
  }

  Future<void> _continue() async {
    final p = _problem;
    if (p != null) {
      setState(() => _error = p);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = AppScope.read(context);
    final l = context.l;
    final existing = _existing;
    final agent = cutForPrompt(existing?.name ?? app.agent);
    final (r, err) = await m.issueAppAgent(
      existing?.name ?? app.agent,
      auth: _auth.auth(m, l.touchIdReasonAgentToken(agent)),
      tasksReason: l.touchIdReasonAgentTasks(agent),
      create: existing == null
          ? NewAgent(
              name: app.agent,
              localLevel: _label!,
              links: _allLinks ? null : _links.toList(),
              everyone: _everyone,
            )
          : null,
      tasksFrom: _tasks,
      setTasks: _tasksChanged,
    );
    _auth.password.clear();
    if (!mounted) return;
    if (r == null) {
      final fellBack = _auth.fellBack(l, m, err);
      setState(() {
        _busy = false;
        _error = fellBack ? null : err;
      });
      return;
    }
    final file = r.tokenFile;
    final plan = file == null ? GuidePlan(app) : m.planConnect(app, file, guide: widget.guide);
    setState(() {
      _busy = false;
      _issued = r;
      _plan = plan;
      _step = plan is GuidePlan ? _Step.guide : _Step.review;
    });
  }

  Future<void> _write() async {
    final plan = _plan;
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = AppScope.read(context);
    try {
      switch (plan) {
        case WriteConfigPlan():
          _backup = await m.applyConnect(plan);
        case OpenLinkPlan():
          if (!await m.openAppLink(plan)) throw StateError('open');
        case GuidePlan() || null:
          break;
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = _Step.done;
      });
    } on ConfigChanged {
      // Show the file as it is now before writing anything.
      final file = _issued?.tokenFile;
      if (!mounted || file == null) return;
      setState(() {
        _busy = false;
        _plan = m.planConnect(app, file);
        _error = context.l.connectChanged;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final actions = switch (_step) {
      _Step.setup => [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
          FilledButton(
            key: const Key('connect-continue'),
            style: XButtons.primary(),
            onPressed: _busy ? null : _continue,
            child: Text(l.connectContinue),
          ),
        ],
      _Step.review => [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
          FilledButton(
            key: const Key('connect-write'),
            style: XButtons.primary(),
            onPressed: _busy ? null : _write,
            child: Text(_plan is OpenLinkPlan ? l.connectOpen(app.name) : l.connectWrite),
          ),
        ],
      _Step.guide || _Step.done => [
          FilledButton(
            key: const Key('connect-done'),
            style: XButtons.primary(),
            onPressed: () => Navigator.pop(context),
            child: Text(l.commonDone),
          ),
        ],
    };
    return XDialogShell(
      title: _step == _Step.guide ? l.guideTitle(app.name) : l.connectTitle(app.name),
      leading: AiLogo(brand: brandOfApp(app.id), label: app.name, size: 34),
      subtitle: appSubtitle(l, app.id),
      width: 680,
      actions: actions,
      child: switch (_step) {
        _Step.setup => _setup(context),
        _Step.review => _review(context),
        _Step.guide => _guide(context),
        _Step.done => _done(context),
      },
    );
  }

  Widget _setup(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final existing = _existing;
    final level5 = [for (final c in m.contacts) if (c.trust == 5) c.label];
    final tasks = _tasks ?? (existing != null && !existing.tasksFromDefault ? existing.tasksFrom ?? level5 : level5);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ConnectNote(
        Icons.smart_toy_outlined,
        existing == null ? l.connectNewAgent(app.agent, app.name) : l.connectExistingAgent(app.name, existing.name),
      ),
      if (existing == null) ...[
        const SizedBox(height: 16),
        SectionLabel(l.codeRole),
        if (!_otherLabel) ...[
          RolePresetChoice(
            value: RolePreset.values.where((r) => r.level == _label).firstOrNull,
            onChanged: (r) => setState(() => _label = r.level),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('connect-other-label'),
              onPressed: () => setState(() => _otherLabel = true),
              child: Text(l.rolePresetOther),
            ),
          ),
        ] else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final d in DataLabel.all)
              DataLabelCard(d, selected: _label == d.level, onTap: () => setState(() => _label = d.level)),
          ]),
        const SizedBox(height: 8),
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
      ],
      const SizedBox(height: 16),
      // Whose messages are tasks: the default is the contacts the owner trusts at level 5.
      Container(
        key: const Key('connect-tasks'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.m)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.task_alt_rounded, size: 17, color: XColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tasks.isEmpty
                    ? (_tasks == null && level5.isEmpty ? l.connectTasksNoneAt5 : l.connectTasksNone)
                    : l.connectTasksFrom(_contactsText(l, m.contacts, tasks)),
                key: const Key('connect-tasks-text'),
                style: XText.body.copyWith(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            const ExperimentalTag(key: Key('experimental-connect-tasks')),
            const SizedBox(width: 4),
            TextButton(
              key: const Key('connect-tasks-change'),
              onPressed: () => setState(() => _editTasks = !_editTasks),
              child: Text(l.connectTasksChange),
            ),
          ]),
          if (_editTasks) ...[
            const SizedBox(height: 8),
            TasksChoice(
              contacts: m.contacts,
              value: _tasks,
              onChanged: (v) => setState(() {
                _tasks = v;
                _tasksChanged = true;
              }),
            ),
          ],
          const SizedBox(height: 8),
          Text(l.tasksAbout, style: XText.meta),
        ]),
      ),
      const SizedBox(height: 16),
      if (existing != null) ...[
        Text(l.codeNewTokenNote, style: XText.meta),
        const SizedBox(height: 8),
      ],
      OwnerAuthField(controller: _auth, onSubmitted: (_) => _continue()),
      if (_error != null)
        _error is String ? ErrorLine(_error! as String) : ErrorLine(describeError(l, _error!), detail: errorDetail(_error!)),
      const SizedBox(height: 12),
      ConnectNote(Icons.key_off_outlined, l.connectNoTokenInConfig),
    ]);
  }

  Widget _review(BuildContext context) {
    final l = context.l;
    final plan = _plan!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      switch (plan) {
        WriteConfigPlan(:final path, :final before) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.connectReviewWrite(path), key: const Key('connect-review-path'), style: XText.body),
            const SizedBox(height: 8),
            CodeBlock(plan.entry, key: const Key('connect-review-entry')),
            const SizedBox(height: 8),
            if (before == null)
              ConnectNote(Icons.note_add_outlined, l.connectReviewNewFile)
            else ...[
              ConnectNote(Icons.inventory_2_outlined, l.connectReviewKeep),
              if (_replacesEntry(plan)) ...[
                const SizedBox(height: 8),
                ConnectNote(Icons.swap_horiz_rounded, l.connectReviewReplace),
              ],
            ],
            const SizedBox(height: 8),
            ConnectNote(Icons.restart_alt_rounded,
                app.config?.restart ?? true ? l.connectReviewRestart(app.name) : l.connectReviewLive(app.name)),
          ]),
        OpenLinkPlan(:final url) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.connectReviewLink(app.name), style: XText.body),
            const SizedBox(height: 8),
            CodeBlock(plan.entry),
            const SizedBox(height: 8),
            Text(url, maxLines: 2, overflow: TextOverflow.ellipsis, style: XText.monoSmall),
          ]),
        GuidePlan() => const SizedBox.shrink(),
      },
      const SizedBox(height: 8),
      ConnectNote(Icons.key_off_outlined, l.connectNoTokenInConfig),
      if (_error != null)
        _error is String ? ErrorLine(_error! as String) : ErrorLine(describeError(context.l, _error!)),
    ]);
  }

  Widget _guide(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final issued = _issued;
    final file = issued?.tokenFile;
    final reason = switch (_plan) { GuidePlan(:final reason?) => reason, _ => null };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (reason != null) ...[
        ConnectNote(Icons.info_outline_rounded, l.connectNotEditable(app.config?.pathFor(m.agentHost?.home ?? '~', macos: m.agentHost?.macos ?? false) ?? '', reason)),
        const SizedBox(height: 8),
      ],
      if (issued == null)
        ConnectNote(Icons.info_outline_rounded, l.guideConnectFirst(app.name))
      else if (file == null) ...[
        // An older daemon: no token file. The token has to be pasted; say where, and offer to replace it.
        TokenWarning(token: issued.token, agent: issued.agent),
        const SizedBox(height: 12),
      ],
      AppGuide(
        app: app,
        server: file == null ? null : m.appServer(file),
        token: file == null && issued != null ? issued.token : null,
        macos: m.agentHost?.macos ?? false,
        cli: m.binaries?.cli ?? 'antenna',
      ),
      if (issued != null) ...[
        const SizedBox(height: 12),
        ConnectLiveStatus(app: app, agent: issued.agent),
      ],
    ]);
  }

  Widget _done(BuildContext context) {
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ConnectNote(Icons.check_circle_outline_rounded, l.connectDone(app.name)),
      if (_backup != null) ...[
        const SizedBox(height: 8),
        Text(l.connectBackup(_backup!), key: const Key('connect-backup'), style: XText.monoSmall),
      ],
      const SizedBox(height: 12),
      ConnectNextSteps(app: app, agent: _issued?.agent ?? app.agent, viaLink: _plan is OpenLinkPlan),
    ]);
  }
}

/// The file already has an `antenna` entry, which the write replaces.
bool _replacesEntry(WriteConfigPlan p) {
  final c = p.app.config;
  if (c == null || p.before == null) return false;
  return switch (c.format) {
    ConfigFormat.json => jsonServer(p.before, key: c.key) != null,
    ConfigFormat.toml => tomlServerArgs(p.before) != null,
  };
}

String _contactsText(AppLocalizations l, List<ContactInfo> contacts, List<String> labels) => [
      for (final n in labels)
        switch (contacts.where((c) => c.label == n).firstOrNull) {
          final c? when c.trust == 5 => '${c.label} (${trustGlyph(5)} · ${l.selfOwnComputerShort})',
          final c? => '${c.label} (${c.trust})',
          null => n,
        },
    ].join(', ');
