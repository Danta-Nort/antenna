// SPDX-License-Identifier: AGPL-3.0-only
// "Files from this computer" on the card of an own computer (trust level 5, D-130, D-UI-46): where its files and each
// of its agents' files are saved (Choose folder…, Default), and which of its programs and installers are saved without
// waiting for Keep anyway. Setting a folder or letting something through takes the owner (one touch or the password);
// going back to the default or taking an entry off does not. The daemon checks every rule; the card shows what it
// lists in `contacts`.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/file_prefs.dart';
import '../../state/media.dart' show shortPath;
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../code/start_agent_dialog.dart' show FolderChooser;
import '../security/owner_confirm.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';

/// How an allowlist entry reads.
String allowEntryLabel(AppLocalizations l, String e) => switch (e) {
      allowExecutables => l.cardAllowExecutables,
      allowInstallers => l.cardAllowInstallers,
      _ => e,
    };

void _say(BuildContext context, Object? err) {
  if (err == null || !context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
}

class FilePrefsSection extends StatelessWidget {
  const FilePrefsSection(this.c, {super.key});
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    if (c.trust < 5) return const SizedBox.shrink();
    final agents = [for (final a in c.activeAgents) a.name];
    return Column(
      key: const Key('card-files'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(l.cardFilesTitle),
        Text(l.cardFilesNote, style: XText.meta),
        const SizedBox(height: 8),
        _FolderRow(c, null, m.saveDirOf(c)),
        for (final a in agents) _FolderRow(c, a, m.saveDirOf(c, agent: a)),
        const SizedBox(height: 16),
        Text(l.cardAllowTitle, style: XText.title),
        const SizedBox(height: 4),
        Text(l.cardAllowNote, style: XText.meta),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final e in c.fileAllow)
            InputChip(
              key: Key('card-allow-$e'),
              label: Text(allowEntryLabel(l, e)),
              onDeleted: () => _disallow(context, c, e),
              deleteButtonTooltipMessage: l.cardAllowRemove,
            ),
          if (!c.fileAllow.contains(allowExecutables))
            _AddButton(c, allowExecutables, key: const Key('card-allow-add-executables')),
          if (!c.fileAllow.contains(allowInstallers))
            _AddButton(c, allowInstallers, key: const Key('card-allow-add-installers')),
          TextButton.icon(
            key: const Key('card-allow-add-extension'),
            onPressed: () => _addExtension(context, c),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: Text(l.cardAllowExtension),
          ),
        ]),
      ],
    );
  }
}

/// Take [e] off the allowlist: no password, it only makes the daemon ask again.
Future<void> _disallow(BuildContext context, ContactInfo c, String e) async {
  final err = await AppScope.read(context).disallowFiles(c, [e]);
  if (context.mounted) _say(context, err);
}

/// Let [entries] through, with the owner's touch or password.
Future<void> _allow(BuildContext context, ContactInfo c, List<String> entries) async {
  final l = context.l;
  final what = entries.map((e) => allowEntryLabel(l, e)).join(', ');
  final (_, err) = await confirmOwner(
    context,
    action: l.cardAllowAction(what, c.label),
    detail: l.cardAllowNote,
    cli: 'antenna files allow ${c.label} ${entries.join(' ')}',
    run: (auth) => AppScope.read(context).allowFiles(c, entries, auth: auth),
  );
  if (context.mounted) _say(context, err);
}

Future<void> _addExtension(BuildContext context, ContactInfo c) async {
  final ext = await showXDialog<String>(context, (_) => const _ExtensionDialog());
  if (ext == null || !context.mounted) return;
  await _allow(context, c, [ext.startsWith('.') ? ext : '.$ext']);
}

class _AddButton extends StatelessWidget {
  const _AddButton(this.c, this.entry, {super.key});
  final ContactInfo c;
  final String entry;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => _allow(context, c, [entry]),
        icon: const Icon(Icons.add_rounded, size: 16),
        label: Text(allowEntryLabel(context.l, entry)),
      );
}

/// One save folder: whose files, where they go, Choose folder… and Default.
class _FolderRow extends StatelessWidget {
  const _FolderRow(this.c, this.agent, this.path);
  final ContactInfo c;
  final String? agent;
  final String? path;

  Future<void> _clear(BuildContext context) async {
    final err = await AppScope.read(context).clearSaveDir(c, agent: agent);
    if (context.mounted) _say(context, err);
  }

  Future<void> _choose(BuildContext context) async {
    final l = context.l;
    final picked = await FolderChooser.instance.pick(l.cardSaveFolderChoose);
    if (picked == null || !context.mounted) return;
    final (_, err) = await confirmOwner(
      context,
      action: l.cardSaveFolderAction(agent ?? c.label, picked),
      cli: 'antenna files save-to ${c.label}${agent == null ? '' : ' --agent $agent'} "$picked"',
      run: (auth) => AppScope.read(context).setSaveDir(c, picked, agent: agent, auth: auth),
    );
    if (context.mounted) _say(context, err);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final id = agent ?? 'person';
    final where = path == null
        ? (agent == null ? l.cardSaveFolderDefault : l.cardSaveFolderAsContact)
        : shortPath(path!, home: Platform.environment['HOME']);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(agent == null ? l.cardSaveFolderContact : l.cardSaveFolderAgent(agent!), style: XText.body),
            Text(where,
                key: Key('card-save-dir-$id'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: XText.monoSmall.copyWith(color: path == null ? XColors.textMute : XColors.textDim)),
          ]),
        ),
        TextButton(
          key: Key('card-save-dir-choose-$id'),
          onPressed: () => _choose(context),
          child: Text(l.cardSaveFolderChoose),
        ),
        if (path != null)
          TextButton(
            key: Key('card-save-dir-clear-$id'),
            onPressed: () => _clear(context),
            child: Text(l.cardSaveFolderClear),
          ),
      ]),
    );
  }
}

/// An extension for the allowlist: a dot and 1–16 letters or digits, as the daemon takes it.
class _ExtensionDialog extends StatefulWidget {
  const _ExtensionDialog();

  @override
  State<_ExtensionDialog> createState() => _ExtensionDialogState();
}

class _ExtensionDialogState extends State<_ExtensionDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String get _ext => _c.text.trim().startsWith('.') ? _c.text.trim() : '.${_c.text.trim()}';

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final ok = allowExtension.hasMatch(_ext);
    return XDialogShell(
      title: l.cardAllowExtension,
      icon: Icons.extension_outlined,
      width: 420,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('card-allow-extension-ok'),
          onPressed: ok ? () => Navigator.pop(context, _ext) : null,
          child: Text(l.cardAllowExtensionOk),
        ),
      ],
      child: TextField(
        key: const Key('card-allow-extension-field'),
        controller: _c,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(hintText: '.dmg', helperText: l.cardAllowExtensionHint),
      ),
    );
  }
}
