// SPDX-License-Identifier: AGPL-3.0-only
// "An agent that replies on its own" (x-control/4, CONTROL §16): a rule "this contact writes → the daemon starts the
// agent in a sandbox, and the reply goes out as a stream". The window only asks the daemon; the daemon owns the
// command, sandbox, proxy, secrets and log. A secret variable (the agent's token) is sent to the daemon once and kept in
// its encrypted database; the window neither shows nor stores it. On an OS without a sandbox the daemon refuses
// (`sandbox_unavailable`; macOS: D-72).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../state/wake.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/x_buttons.dart';
import 'resident_ui.dart';

/// A `wake_set` error in plain words.
String describeWakeError(AppLocalizations l, Object e) => switch (e) {
      XControlException(code: XErrorCode.denied) => l.wakeErrDenied,
      XControlException(code: XErrorCode.sandboxUnavailable) => l.wakeErrNoSandbox,
      XControlException(code: XErrorCode.badRequest, :final message) => l.wakeErrBadRequest(message),
      _ => describeError(l, e),
    };

/// Outcome of a run: label and color.
(String, Color) wakeOutcomeLook(AppLocalizations l, String outcome) => switch (outcome) {
      'ok' => (l.wakeOutcomeOk, XColors.ok),
      'running' => (l.wakeOutcomeRunning, XColors.accent),
      'timeout' => (l.wakeOutcomeTimeout, XColors.warn),
      'stopped' => (l.wakeOutcomeStopped, XColors.textDim),
      'refused' => (l.wakeOutcomeRefused, XColors.warn),
      'failed' => (l.wakeOutcomeFailed, XColors.danger),
      final o => (o, XColors.textDim),
    };

Future<void> showWakeDialog(BuildContext context, {String? linkId}) =>
    showXDialog<void>(context, (_) => WakeDialog(linkId: linkId), dismissible: false);

class WakeDialog extends StatefulWidget {
  const WakeDialog({super.key, this.linkId});

  /// Link chosen in advance (from the contact card).
  final String? linkId;

  @override
  State<WakeDialog> createState() => _WakeDialogState();
}

class _WakeDialogState extends State<WakeDialog> {
  String? _link;
  WakePreset _preset = WakePreset.claude;
  final _cmd = TextEditingController(text: WakePreset.claude.command);
  final _secretName = TextEditingController(text: WakePreset.claude.secretName);
  final _secretValue = TextEditingController();
  final _hosts = TextEditingController();
  final _timeout = TextEditingController(text: '10');
  final _perHour = TextEditingController(text: '20');
  final _auth = OwnerAuthController();
  bool _noHomeFiles = false;
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _link = widget.linkId;
    final m = AppScope.read(context);
    final rule = _link == null ? null : m.wakeRuleOf(_link!);
    if (rule != null) {
      // Editing a rule: command and limits start from the current values; the daemon never returns secrets (they can be set again).
      _cmd.text = rule.argv.map((a) => a.contains(' ') ? '"$a"' : a).join(' ');
      _preset = WakePreset.custom;
      _timeout.text = '${(rule.timeoutSecs / 60).ceil()}';
      _perHour.text = '${rule.maxRunsPerHour}';
      _noHomeFiles = rule.homeFiles.isEmpty;
      _secretName.text = rule.secretEnv.isEmpty ? '' : rule.secretEnv.first;
    }
  }

  @override
  void dispose() {
    for (final c in [_cmd, _secretName, _secretValue, _hosts, _timeout, _perHour]) {
      c.dispose();
    }
    _auth.dispose();
    super.dispose();
  }

  void _pick(WakePreset p) => setState(() {
        _preset = p;
        if (p != WakePreset.custom) _cmd.text = p.command;
        if (_secretValue.text.isEmpty) _secretName.text = p.secretName;
      });

  Future<void> _submit() async {
    final l = context.l;
    final m = AppScope.read(context);
    final c = _link == null ? null : m.contactById(_link!);
    final argv = splitCommand(_cmd.text.trim());
    final secretName = _secretName.text.trim();
    final secretValue = _secretValue.text;
    final timeoutMin = int.tryParse(_timeout.text.trim());
    final perHour = int.tryParse(_perHour.text.trim());
    final problem = c == null
        ? l.wakeErrContact
        : (argv == null || argv.isEmpty)
            ? l.wakeErrCommand
            : (secretValue.isNotEmpty && !RegExp(r'^[A-Z_][A-Z0-9_]*$').hasMatch(secretName))
                ? l.wakeErrSecretName
                : (timeoutMin == null || timeoutMin < 1 || timeoutMin > 60)
                    ? l.wakeErrTimeout
                    : (perHour == null || perHour < 1 || perHour > 200)
                        ? l.wakeErrPerHour
                        : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final hosts = _hosts.text.split(RegExp(r'[\s,]+')).where((h) => h.isNotEmpty).toList();
    final contact = c!;
    final err = await m.setWake(
        _auth.auth(m, touchIdConfirmReason(l, l.wakeTitle)),
        (pw) => WakeSetRequest(
              contact: contact.linkId,
              argv: argv!,
              password: pw,
              timeoutSecs: timeoutMin! * 60,
              maxRunsPerHour: perHour,
              allowHosts: hosts,
              homeFiles: _noHomeFiles ? const [] : null,
              secretEnv: secretValue.isEmpty ? const [] : [SecretEnvVar(secretName, secretValue)],
            ));
    _auth.password.clear();
    if (!mounted) return;
    if (err == null) {
      _secretValue.clear();
      Navigator.pop(context);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l.wakeEnabled(contact.label))));
      return;
    }
    final fellBack = _auth.fellBack(l, m, err);
    setState(() {
      _busy = false;
      _error = fellBack ? null : describeWakeError(l, err);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final c = _link == null ? null : m.contactById(_link!);
    return XDialogShell(
      title: l.wakeTitle,
      icon: Icons.bolt_outlined,
      subtitle: l.wakeSubtitle,
      width: 720,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('wake-submit'),
          onPressed: _busy ? null : _submit,
          child: Text(l.wakeSubmit),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        WakeSandboxNote(sandbox: m.wakeSandbox, detail: m.wakeSandboxDetail),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: const Key('wake-contact'),
          initialValue: _link,
          decoration: InputDecoration(labelText: l.wakeContact),
          items: [
            for (final x in m.contacts)
              DropdownMenuItem(
                value: x.linkId,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(x.label),
                  const SizedBox(width: 8),
                  TrustBadge(x.trust, size: 16),
                ]),
              ),
          ],
          onChanged: widget.linkId != null ? null : (v) => setState(() => _link = v),
        ),
        if (c != null && c.trust < 3) ...[
          const SizedBox(height: 8),
          Text(l.wakeLowTrustNote, style: XText.meta.copyWith(color: XColors.warn)),
        ],
        const SizedBox(height: 16),
        Text(l.wakeAgentLabel, style: XText.label),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (p, label) in [
            (WakePreset.claude, l.wakePresetClaude),
            (WakePreset.codex, l.wakePresetCodex),
            (WakePreset.custom, l.wakePresetCustom),
          ])
            ChoiceChip(
              key: Key('wake-preset-${p.name}'),
              label: Text(label),
              selected: _preset == p,
              onSelected: (_) => _pick(p),
              showCheckmark: false,
            ),
        ]),
        const SizedBox(height: 12),
        TextField(
          key: const Key('wake-cmd'),
          controller: _cmd,
          style: XText.mono.copyWith(color: XColors.text),
          decoration: InputDecoration(labelText: l.wakeCommand, helperText: l.wakeCommandHelp, helperMaxLines: 3),
          onChanged: (_) => setState(() => _preset = WakePreset.values.firstWhere(
                (p) => p != WakePreset.custom && p.command == _cmd.text.trim(),
                orElse: () => WakePreset.custom,
              )),
        ),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 250,
            child: TextField(
              key: const Key('wake-secret-name'),
              controller: _secretName,
              style: XText.mono.copyWith(color: XColors.text),
              decoration: InputDecoration(labelText: l.wakeSecretName),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const Key('wake-secret-value'),
              controller: _secretValue,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              style: XText.mono.copyWith(color: XColors.text),
              decoration: InputDecoration(
                labelText: l.wakeSecretValue,
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 17),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onChanged: (v) => setState(() {
                if (v.isNotEmpty) _noHomeFiles = true;
              }),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Text(l.wakeSecretHelp, style: XText.meta),
        const SizedBox(height: 8),
        // Own Material: the dialog panel is a DecoratedBox with a fill, and ListTile paints its background on the nearest Material.
        Material(
          type: MaterialType.transparency,
          child: CheckboxListTile(
            key: const Key('wake-no-home-files'),
            value: _noHomeFiles,
            onChanged: (v) => setState(() => _noHomeFiles = v ?? false),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(l.wakeNoHomeFiles, style: XText.body),
            subtitle: Text(l.wakeNoHomeFilesHelp, style: XText.meta),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('wake-hosts'),
          controller: _hosts,
          style: XText.mono.copyWith(color: XColors.text),
          decoration: InputDecoration(labelText: l.wakeHosts, helperText: l.wakeHostsHelp, helperMaxLines: 2),
        ),
        const SizedBox(height: 12),
        Row(children: [
          SizedBox(
            width: 200,
            child: TextField(
              key: const Key('wake-timeout'),
              controller: _timeout,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l.wakeTimeout),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 200,
            child: TextField(
              key: const Key('wake-per-hour'),
              controller: _perHour,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l.wakePerHour),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        OwnerAuthField(controller: _auth, onSubmitted: (_) => _submit()),
        if (_error != null) ErrorLine(_error!),
      ]),
    );
  }
}

/// Which sandbox the agent gets on this OS, stated plainly.
class WakeSandboxNote extends StatelessWidget {
  const WakeSandboxNote({super.key, required this.sandbox, required this.detail});
  final String sandbox;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    // Not known yet (daemon older than v4): promise nothing.
    if (sandbox.isEmpty) return const SizedBox.shrink();
    final none = sandbox == 'none';
    final color = none ? XColors.warn : XColors.accent;
    return Container(
      key: const Key('wake-sandbox'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: none ? Color.alphaBlend(XColors.warn.withValues(alpha: 0.09), XColors.bg1) : XColors.accentSoft,
        borderRadius: BorderRadius.circular(XRadius.m),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(none ? Icons.warning_amber_rounded : Icons.shield_outlined, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              switch (sandbox) {
                'none' => l.wakeSandboxNone,
                'bwrap' => l.wakeSandboxBwrap,
                'landlock' => l.wakeSandboxLandlock,
                'seatbelt' => l.wakeSandboxSeatbelt,
                final other => other,
              },
              style: XText.body.copyWith(color: XColors.text),
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(detail, style: XText.monoSmall),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// A rule: who wakes, who replies, how, the last run; log, edit, turn off.
class WakeRuleCard extends StatelessWidget {
  const WakeRuleCard(this.r, {super.key, this.compact = false});
  final WakeRuleInfo r;

  /// In the contact card: without the contact's name.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final last = r.last;
    final ev = m.lastWakeEvent[r.linkId];
    final facts = <String>[
      r.mode == 'claude_stream' ? l.wakeModeStream : l.wakeModePlain,
      l.wakeTimeoutFact((r.timeoutSecs / 60).ceil()),
      l.wakePerHourFact(r.maxRunsPerHour),
      if (r.allowHosts.isNotEmpty) l.wakeHostsFact(r.allowHosts.join(', ')),
      r.homeFiles.isEmpty ? l.wakeNoHomeFilesFact : l.wakeHomeFilesFact(r.homeFiles.join(', ')),
      if (r.secretEnv.isNotEmpty) l.wakeSecretsFact(r.secretEnv.join(', ')),
      if (r.project case final p?) l.wakeProjectFact(p),
      if (r.toolPaths.isNotEmpty) l.wakeToolsFact(r.toolPaths.join(', ')),
    ];
    return Column(
      key: Key('wake-rule-${r.contact}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.bolt_outlined, size: 18, color: XColors.agent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              compact ? r.agent : l.wakeRuleTitle(r.contact, r.agent),
              style: XText.title.copyWith(fontSize: 14),
            ),
          ),
          if (r.running)
            _Tag(l.wakeRunning, XColors.accent)
          else if (r.pending)
            _Tag(l.wakePending, XColors.warn),
        ]),
        const SizedBox(height: 8),
        SelectableText(r.argv.join(' '), style: XText.mono.copyWith(color: XColors.text, fontSize: 11)),
        const SizedBox(height: 8),
        Text(facts.join(' · '), style: XText.meta),
        if (r.resident != null) ...[
          const SizedBox(height: XSpace.m),
          ResidentBlock(r),
        ],
        if (last != null) ...[
          const SizedBox(height: 8),
          _LastRun(last),
        ] else if (ev != null) ...[
          const SizedBox(height: 8),
          Text(l.wakeLastEvent(ev.state), style: XText.meta),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          TextButton.icon(
            key: Key('wake-log-${r.contact}'),
            onPressed: () => showWakeLog(context, r),
            icon: const Icon(Icons.receipt_long_outlined, size: 16),
            label: Text(l.wakeLog),
          ),
          TextButton.icon(
            key: Key('wake-edit-${r.contact}'),
            onPressed: () => showWakeDialog(context, linkId: r.linkId),
            icon: const Icon(Icons.tune, size: 16),
            label: Text(l.wakeEdit),
          ),
          TextButton.icon(
            key: Key('wake-off-${r.contact}'),
            style: XButtons.destructive(),
            onPressed: () async {
              final err = await AppScope.read(context).wakeOff(r.linkId);
              if (err != null && context.mounted) {
                ScaffoldMessenger.maybeOf(context)
                    ?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
              }
            },
            icon: const Icon(Icons.power_settings_new, size: 16),
            label: Text(l.wakeOff),
          ),
        ]),
      ],
    );
  }
}

class _LastRun extends StatelessWidget {
  const _LastRun(this.r);
  final WakeRunInfo r;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final (label, color) = wakeOutcomeLook(l, r.outcome);
    final at = DateTime.fromMillisecondsSinceEpoch(r.startedMs);
    final secs = r.endedMs == null ? null : ((r.endedMs! - r.startedMs) / 1000).toStringAsFixed(1);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Tag(label, color),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          [
            l.wakeLastRun(formatDateTime(l, at)),
            ?(secs == null ? null : l.wakeDuration(secs)),
            ?(r.exitCode == null ? null : l.wakeExitCode(r.exitCode!)),
            if (r.sandbox.isNotEmpty) r.sandbox,
            if (r.detail.isNotEmpty) r.detail,
          ].join(' · '),
          style: XText.meta,
        ),
      ),
    ]);
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Color.alphaBlend(color.withValues(alpha: 0.10), XColors.bg1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: XText.meta.copyWith(color: color, fontWeight: FontWeight.w600)),
      );
}

/// Run log: the `wake` entries of the link's log (`antenna log <contact>`).
Future<void> showWakeLog(BuildContext context, WakeRuleInfo r) => showXDialog<void>(
      context,
      (ctx) => XDialogShell(
        title: ctx.l.wakeLogTitle(r.contact),
        icon: Icons.receipt_long_outlined,
        width: 720,
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l.commonClose))],
        child: _WakeLog(r),
      ),
    );

class _WakeLog extends StatefulWidget {
  const _WakeLog(this.r);
  final WakeRuleInfo r;

  @override
  State<_WakeLog> createState() => _WakeLogState();
}

class _WakeLogState extends State<_WakeLog> {
  late final Future<List<ReceiptInfo>> _log =
      AppScope.read(context).daemon.log(widget.r.linkId, limit: 200).then((x) => x.where((e) => e.action == 'wake').toList());

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return FutureBuilder<List<ReceiptInfo>>(
      future: _log,
      builder: (context, s) {
        if (s.hasError) return Text(describeError(l, s.error!), style: XText.bodyDim.copyWith(color: XColors.danger));
        if (!s.hasData) return const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()));
        final rows = s.data!.reversed.toList();
        if (rows.isEmpty) return Text(l.wakeLogEmpty, style: XText.bodyDim);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('antenna log ${widget.r.contact}', style: XText.monoSmall),
          const SizedBox(height: 8),
          for (final e in rows)
            Padding(
              key: Key('wake-log-row-${e.seq}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 130,
                  child: Text(formatDateTime(l, DateTime.fromMillisecondsSinceEpoch(e.ts)), style: XText.meta),
                ),
                _Tag(wakeOutcomeLook(l, e.decision).$1, wakeOutcomeLook(l, e.decision).$2),
                const SizedBox(width: 8),
                Expanded(child: SelectableText(e.reason, style: XText.monoSmall.copyWith(color: XColors.textDim))),
              ]),
            ),
        ]);
      },
    );
  }
}

/// The "Agents that reply on their own" section of the Agents page.
class WakeRulesSection extends StatelessWidget {
  const WakeRulesSection({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    if (!m.wakeSupported) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: Text(l.wakeSectionTitle, style: XText.h2)),
        FilledButton.icon(
          key: const Key('wake-add'),
          onPressed: () => showWakeDialog(context),
          icon: const Icon(Icons.bolt_outlined, size: 18),
          label: Text(l.wakeAdd),
        ),
      ]),
      const SizedBox(height: 8),
      Text(l.wakeSectionAbout, style: XText.bodyDim),
      const SizedBox(height: 16),
      if (m.wakeSandbox.isNotEmpty) ...[
        WakeSandboxNote(sandbox: m.wakeSandbox, detail: ''),
        const SizedBox(height: 16),
      ],
      if (m.wakeRules.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, glow: 0.6),
          child: Text(l.wakeEmpty, style: XText.bodyDim),
        )
      else
        for (final r in m.wakeRules)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
            decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, glow: 0.6),
            child: WakeRuleCard(r),
          ),
    ]);
  }
}

/// In the contact card: this link's rule, or "set up".
class WakeContactSection extends StatelessWidget {
  const WakeContactSection(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    if (!m.wakeSupported) return const SizedBox.shrink();
    final r = m.wakeRuleOf(c.linkId);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(l.wakeCardTitle),
      if (r != null)
        WakeRuleCard(r, compact: true)
      else ...[
        Text(l.wakeCardAbout, style: XText.bodyDim),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('wake-card-setup'),
            onPressed: () => showWakeDialog(context, linkId: c.linkId),
            icon: const Icon(Icons.bolt_outlined, size: 16),
            label: Text(l.wakeCardSetup),
          ),
        ),
      ],
    ]);
  }
}
