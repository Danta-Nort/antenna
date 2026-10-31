// SPDX-License-Identifier: AGPL-3.0-only
// Agents → Local models (x-control/7, CONTROL §24; docs/LOCAL-ASSISTANT.md §7.1, §7.3; experimental, D-94). Two kinds
// of things, kept apart on purpose: a model is a file on this computer (download, progress, check, remove); a local
// agent is an ordinary agent of this node that the daemon runs on a ready model, with its own conversation, and
// several agents may run on one model. The card shows the computer as the daemon read it, the model it recommends,
// the others behind a disclosure with their fit in plain words, and the local agents. Everything is the daemon's: the
// window keeps no state of its own beyond what is open on screen.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../files/file_card.dart' show fileSizeLabel;
import '../pictures/picture_picker.dart';
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/local_badge.dart';
import '../widgets/section_page.dart';
import '../widgets/x_buttons.dart';
import 'local_agent_dialog.dart';

const _gib = 1024 * 1024 * 1024;

/// Whole gigabytes for the computer's line (`16 GB`).
String _gb(int bytes) => '${(bytes / _gib).round()} GB';

/// How a model suits this computer, in plain words.
String localFitLabel(AppLocalizations l, LocalModelInfo m) => switch (m.fit) {
      LocalFit.recommended => l.localFitRecommended,
      LocalFit.fits => l.localFitFits,
      LocalFit.slow => l.localFitSlow,
      LocalFit.tooBig => l.localFitTooBig(fileSizeLabel(m.memoryBytes)),
      LocalFit.unsupported => l.localFitUnsupported,
      final f => f,
    };

/// Why a model's download or check failed, by its code.
String localModelError(AppLocalizations l, String? code) => switch (code) {
      XErrorCode.hashMismatch => l.localErrHashMismatch,
      XErrorCode.noSpace => l.localErrNoSpace,
      XErrorCode.fetchFailed => l.localErrFetchFailed,
      XErrorCode.sandboxUnavailable => l.localErrSandbox,
      final c => l.localErrOther(c ?? '—'),
    };

/// Agents → Local models. [onOpenChat] opens a local agent's conversation in Chats.
class LocalModelsCard extends StatefulWidget {
  const LocalModelsCard({super.key, required this.onOpenChat});
  final ValueChanged<String> onOpenChat;

  @override
  State<LocalModelsCard> createState() => _LocalModelsCardState();
}

class _LocalModelsCardState extends State<LocalModelsCard> {
  bool _others = false;

  /// A `model_install` the daemon refused before it started (`no_space`, …), by model: the model's state did not
  /// change, so the reason is said here.
  final Map<String, Object> _refused = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).refreshLocalModels();
    });
  }

  Future<void> _download(LocalModelInfo model) async {
    final ok = await showXDialog<bool>(context, (_) => _DownloadConfirm(model));
    if (ok != true || !mounted) return;
    final err = await AppScope.read(context).installLocalModel(model.id);
    if (!mounted) return;
    setState(() => err == null ? _refused.remove(model.id) : _refused[model.id] = err);
  }

  Future<void> _cancel(LocalModelInfo model) async {
    final err = await AppScope.read(context).removeLocalModel(model.id);
    if (err != null && mounted) _snack(err);
  }

  Future<void> _remove(LocalModelInfo model) async {
    final ok = await showXDialog<bool>(context, (_) => _RemoveConfirm(model));
    if (ok != true || !mounted) return;
    final err = await AppScope.read(context).removeLocalModel(model.id);
    if (err != null && mounted) _snack(err);
  }

  Future<void> _create(LocalModelInfo model) async {
    final name = await showLocalAgentDialog(context, model);
    if (name != null && mounted) widget.onOpenChat(name);
  }

  Future<void> _removeAgent(LocalAgentInfo a) async {
    final l = context.l;
    final m = AppScope.read(context);
    final (_, err) = await confirmOwner(context,
        action: l.localAgentRemoveAction(a.name),
        detail: l.localAgentRemoveDetail,
        cli: 'antenna agent remove ${a.name}',
        run: (auth) => m.removeLocalAgent(a.name, auth));
    if (err != null && mounted) _snack(err);
  }

  void _snack(Object err) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    // A daemon older than x-control/7 has no local models: the card is not shown at all.
    if (!m.localModelsSupported) return const SizedBox.shrink();
    final hw = m.localHardware;
    final rt = m.localRuntime;
    final models = m.localModels;
    final unsupported = models.isNotEmpty && models.every((x) => x.fit == LocalFit.unsupported);
    final main = [for (final x in models) if (x.fit == LocalFit.recommended || x.state != LocalModelState.available) x];
    final others = [for (final x in models) if (!main.contains(x)) x];
    return SectionCard(
      key: const Key('local-models'),
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Flexible(child: Text(l.localTitle, style: XText.title)),
          const SizedBox(width: 8),
          const ExperimentalTag(key: Key('experimental-local-models')),
        ]),
        const SizedBox(height: 4),
        Text(l.localAbout, style: XText.bodyDim),
        const SizedBox(height: 12),
        if (hw == null)
          Text(m.localError == null ? l.commonLoading : describeError(l, m.localError!), style: XText.meta)
        else
          _Fact(
            hw.macos ? Icons.laptop_mac_rounded : Icons.computer_rounded,
            l.localThisComputer(hw.cpu.isEmpty ? hw.arch : hw.cpu, _gb(hw.memoryBytes), _gb(hw.diskFreeBytes)),
            key: const Key('local-computer'),
          ),
        if (rt != null && !rt.available && !unsupported)
          _Fact(
            Icons.info_outline_rounded,
            rt.version.isEmpty
                ? l.localNoRuntime
                : (rt.sandbox == 'none' ? l.localNoSandbox : l.localRuntimeUnavailable),
            detail: rt.detail,
            color: XColors.warn,
            key: const Key('local-runtime-missing'),
          ),
        if (unsupported)
          _Fact(Icons.info_outline_rounded, l.localUnsupported, color: XColors.warn, key: const Key('local-unsupported')),
        for (final x in main)
          _ModelRow(
            x,
            refused: _refused[x.id],
            onDownload: () => _download(x),
            onCancel: () => _cancel(x),
            onRemove: () => _remove(x),
            onCreate: () => _create(x),
          ),
        if (others.isNotEmpty) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('local-other-models'),
              style: XButtons.tertiary(),
              onPressed: () => setState(() => _others = !_others),
              icon: Icon(_others ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
              label: Text(l.localOtherModels(others.length)),
            ),
          ),
          if (_others)
            for (final x in others)
              _ModelRow(
                x,
                refused: _refused[x.id],
                onDownload: () => _download(x),
                onCancel: () => _cancel(x),
                onRemove: () => _remove(x),
                onCreate: () => _create(x),
              ),
        ],
        const SizedBox(height: 12),
        Text(l.localAgentsHeader.toUpperCase(), style: XText.overline),
        const SizedBox(height: 4),
        if (m.localAgents.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(l.localAgentsEmpty, key: const Key('local-agents-empty'), style: XText.bodyDim),
          )
        else
          for (final a in m.localAgents)
            _LocalAgentRow(a, onChat: () => widget.onOpenChat(a.name), onRemove: () => _removeAgent(a)),
        const SizedBox(height: 12),
        Text(l.localComingNext, key: const Key('local-coming-next'), style: XText.meta),
      ]),
    );
  }
}

/// One line about the computer or the runtime, with the daemon's English detail under it when there is one.
class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text, {super.key, this.detail = '', this.color});
  final IconData icon;
  final String text;
  final String detail;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: color ?? XColors.textDim)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(text, style: XText.body.copyWith(color: color == null ? XColors.textDim : XColors.text)),
              if (detail.isNotEmpty) Text(detail, style: XText.meta),
            ]),
          ),
        ]),
      );
}

/// A small chip: a dot and one word or phrase.
class _Chip extends StatelessWidget {
  const _Chip(this.text, this.color, {super.key, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Color.alphaBlend(color.withValues(alpha: XColors.isDark ? 0.16 : 0.10), XColors.bg1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null)
            Icon(icon, size: 12, color: color)
          else
            Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(text, style: XText.meta.copyWith(color: color, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// A catalog model: what it is, how it suits this computer, its state here and the one action that fits the state.
class _ModelRow extends StatelessWidget {
  const _ModelRow(
    this.x, {
    required this.refused,
    required this.onDownload,
    required this.onCancel,
    required this.onRemove,
    required this.onCreate,
  });

  final LocalModelInfo x;
  final Object? refused;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onRemove;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final fitColor = switch (x.fit) {
      LocalFit.recommended => XColors.ok,
      LocalFit.fits => XColors.textDim,
      LocalFit.slow || LocalFit.tooBig => XColors.warn,
      _ => XColors.textMute,
    };
    final speed = x.estTokensPerS;
    final facts = [
      if (x.maker.isNotEmpty) x.maker,
      l.localModelDownload(fileSizeLabel(x.sizeBytes)),
      l.localModelMemory(fileSizeLabel(x.memoryBytes)),
      if (speed != null && speed > 0 && x.fit != LocalFit.unsupported) l.localModelSpeed(((speed * 3) / 4).ceil()),
    ].join(' · ');
    final Widget? state = switch (x.state) {
      LocalModelState.downloading => _Progress(x, key: Key('local-progress-${x.id}')),
      LocalModelState.verifying => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 8),
          LinearProgressIndicator(minHeight: 4, color: XColors.accentFill, backgroundColor: XColors.accentSoft),
          const SizedBox(height: 4),
          Text(l.localVerifying, key: Key('local-verifying-${x.id}'), style: XText.meta),
        ]),
      LocalModelState.failed => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(localModelError(l, x.errorCode), key: Key('local-failed-${x.id}'),
                style: XText.bodyDim.copyWith(color: XColors.danger)),
            if ((x.error ?? '').isNotEmpty && x.errorCode != XErrorCode.hashMismatch) Text(x.error!, style: XText.meta),
          ]),
        ),
      _ => null,
    };
    final refusedText = switch (refused) {
      XControlException(:final code, :final message) when code == XErrorCode.noSpace => '${l.localErrNoSpace} $message',
      final Object e => describeError(l, e),
      null => null,
    };
    final List<Widget> actions = switch (x.state) {
      LocalModelState.available when x.fit != LocalFit.unsupported => [
          if (x.fit == LocalFit.recommended)
            FilledButton(key: Key('local-download-${x.id}'), onPressed: onDownload, child: Text(l.localDownload))
          else
            OutlinedButton(key: Key('local-download-${x.id}'), onPressed: onDownload, child: Text(l.localDownload)),
        ],
      LocalModelState.downloading => [
          TextButton(
              key: Key('local-cancel-${x.id}'), style: XButtons.destructive(), onPressed: onCancel, child: Text(l.commonCancel)),
        ],
      LocalModelState.ready => [
          FilledButton(key: Key('local-create-${x.id}'), onPressed: onCreate, child: Text(l.localCreateAgent)),
          TextButton(
              key: Key('local-remove-${x.id}'), style: XButtons.destructive(), onPressed: onRemove, child: Text(l.localRemove)),
        ],
      LocalModelState.failed => [
          OutlinedButton(key: Key('local-retry-${x.id}'), onPressed: onDownload, child: Text(l.localTryAgain)),
        ],
      _ => const [],
    };
    return Container(
      key: Key('local-model-${x.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: XColors.bg2,
        borderRadius: BorderRadius.circular(XRadius.l),
        border: x.fit == LocalFit.recommended ? Border.all(color: XColors.ok.withValues(alpha: 0.35)) : null,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: XColors.bg1, borderRadius: BorderRadius.circular(XRadius.m)),
          child: Icon(Icons.memory_rounded, size: 20, color: XColors.textDim),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(x.name, style: XText.title.copyWith(fontSize: 14)),
              if (x.state == LocalModelState.ready)
                _Chip(l.localReady, XColors.ok, icon: Icons.check_circle_rounded, key: Key('local-ready-${x.id}'))
              else
                _Chip(localFitLabel(l, x), fitColor, key: Key('local-fit-${x.id}')),
              if (x.loaded) Text(l.localInMemory, style: XText.meta),
            ]),
            const SizedBox(height: 2),
            Text(facts, style: XText.meta.copyWith(color: XColors.textDim)),
            _License(x),
            if (x.agents.isNotEmpty) Text(l.localModelAgents(x.agents.join(', ')), style: XText.meta),
            ?state,
            if (refusedText != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(refusedText,
                    key: Key('local-refused-${x.id}'), style: XText.bodyDim.copyWith(color: XColors.danger)),
              ),
            if (x.fit == LocalFit.unsupported && m.localHardware != null && x.fitDetail.isNotEmpty)
              Text(x.fitDetail, style: XText.meta),
          ]),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(width: 12),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: actions),
        ],
      ]),
    );
  }
}

/// "Apache-2.0 · license", opening the license text the catalog names.
class _License extends StatelessWidget {
  const _License(this.x);
  final LocalModelInfo x;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final url = x.licenseUrl;
    // Only the catalog's own https address: a signed field of this release, never text from a model or a contact.
    final open = url.startsWith('https://');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(l.localModelLicense(x.license), style: XText.meta),
      if (open) ...[
        const SizedBox(width: 4),
        InkWell(
          key: Key('local-license-${x.id}'),
          onTap: () => AppScope.read(context).openExternal(url),
          child: Text(l.localReadLicense, style: XText.meta.copyWith(color: XColors.accent)),
        ),
      ],
    ]);
  }
}

/// Download progress: a bar, done of size, speed, time left.
class _Progress extends StatelessWidget {
  const _Progress(this.x, {super.key});
  final LocalModelInfo x;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final size = x.sizeBytes;
    final done = x.doneBytes.clamp(0, size == 0 ? x.doneBytes : size);
    final speed = x.speedBytesPerS;
    final left = speed == null || speed <= 0 || size <= done ? null : Duration(seconds: ((size - done) / speed).ceil());
    final line = [
      l.localProgress(fileSizeLabel(done), fileSizeLabel(size)),
      if (speed != null && speed > 0) l.localSpeed(fileSizeLabel(speed)),
      if (left != null) l.localTimeLeft(countdown(left)),
    ].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8),
      LinearProgressIndicator(
        minHeight: 4,
        value: size == 0 ? null : done / size,
        color: XColors.accentFill,
        backgroundColor: XColors.accentSoft,
        borderRadius: BorderRadius.circular(2),
      ),
      const SizedBox(height: 4),
      Text(line, style: XText.meta),
    ]);
  }
}

/// A local agent: its name, the Local badge (from the daemon's `runtime`), its model, its state, and Chat.
class _LocalAgentRow extends StatelessWidget {
  const _LocalAgentRow(this.a, {required this.onChat, required this.onRemove});
  final LocalAgentInfo a;
  final VoidCallback onChat;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final model = m.localModel(a.model)?.name ?? a.model;
    final color = localAgentStateColor(a.state);
    return Padding(
      key: Key('local-agent-${a.name}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        XAvatar(a.name, size: 34, agent: true, picture: m.pictureOfMine(agent: a.name)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(a.name, style: XText.title.copyWith(fontSize: 14)),
              LocalBadge(a),
            ]),
            const SizedBox(height: 2),
            Tooltip(
              message: a.detail,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text('$model · ${localAgentStateLabel(l, a.state)}',
                      key: Key('local-agent-state-${a.name}'), style: XText.meta.copyWith(color: XColors.textDim)),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: Key('local-chat-${a.name}'),
          onPressed: onChat,
          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
          label: Text(l.localChat),
        ),
        PopupMenuButton<int>(
          key: Key('local-agent-menu-${a.name}'),
          tooltip: l.appsMore,
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
          onSelected: (v) => v == 1 ? showPicturePicker(context, agent: a.name) : onRemove(),
          itemBuilder: (_) => [
            // A local agent is one of the owner's agents: its picture is set like any other's (CONTROL §28)
            if (m.picturesSupported)
              PopupMenuItem(value: 1, key: Key('local-agent-picture-${a.name}'), child: Text(l.agentPictureAction)),
            PopupMenuItem(value: 0, key: Key('local-agent-remove-${a.name}'), child: Text(l.localAgentRemove)),
          ],
        ),
      ]),
    );
  }
}

/// "Download (model)?": where the bytes come from, that it runs here without internet afterwards, and its license.
class _DownloadConfirm extends StatelessWidget {
  const _DownloadConfirm(this.x);
  final LocalModelInfo x;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return XDialogShell(
      title: l.localDownloadTitle(x.name),
      icon: Icons.download_rounded,
      titleTag: const ExperimentalTag(),
      width: 520,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('local-download-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l.localDownload),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.localDownloadBody(fileSizeLabel(x.sizeBytes), x.host.isEmpty ? 'huggingface.co' : x.host),
            style: XText.body),
        const SizedBox(height: 8),
        Text(l.localDownloadCheck, style: XText.bodyDim),
        const SizedBox(height: 8),
        _License(x),
      ]),
    );
  }
}

/// "Remove (model) from this computer?": the file goes, its agents stay.
class _RemoveConfirm extends StatelessWidget {
  const _RemoveConfirm(this.x);
  final LocalModelInfo x;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return XDialogShell(
      title: l.localRemoveTitle(x.name),
      icon: Icons.delete_outline_rounded,
      width: 480,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('local-remove-confirm'),
          style: XButtons.destructiveFilled(),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l.localRemove),
        ),
      ],
      child: Text(x.agents.isEmpty ? l.localRemoveBody : l.localRemoveBodyAgents(x.agents.join(', ')),
          style: XText.body),
    );
  }
}
