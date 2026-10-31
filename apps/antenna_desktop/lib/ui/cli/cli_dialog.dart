// SPDX-License-Identifier: AGPL-3.0-only
// "antenna command in the terminal" (DECISIONS D-58): a symlink `~/.local/bin/antenna` to the CLI inside the app,
// without administrator rights; on macOS, by explicit choice, `/usr/local/bin/antenna` through macOS's own password prompt.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../host/cli_install.dart';
import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';
import '../../version.dart';
import '../app_scope.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';

Future<void> showCliDialog(BuildContext context) => showXDialog<void>(context, (_) => const CliDialog());

class CliDialog extends StatefulWidget {
  const CliDialog({super.key});

  @override
  State<CliDialog> createState() => _CliDialogState();
}

class _CliDialogState extends State<CliDialog> {
  CliStatus? _status;
  bool _busy = false;
  String? _error;
  String? _done;

  CliInstaller? get _installer => AppScope.of(context).cliInstaller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_status == null && !_busy) _refresh();
  }

  Future<void> _refresh() async {
    final i = _installer;
    if (i == null) return;
    final s = await i.status();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _act(Future<String?> Function(CliInstaller i) f) async {
    final i = _installer;
    if (i == null) return;
    final l = context.l;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final msg = await f(i);
      final s = await i.status();
      if (mounted) {
        setState(() {
          _status = s;
          _done = msg;
        });
      }
    } on CliInstallException catch (e) {
      if (mounted) setState(() => _error = describeCliInstallError(l, e));
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = _installer;
    final s = _status;
    final l = context.l;
    return XDialogShell(
      title: l.cliTitle,
      icon: Icons.terminal,
      width: 620,
      subtitle: l.cliSubtitle,
      actions: [
        if (i != null && i.offersSystemInstall)
          OutlinedButton(
            key: const Key('cli-install-system'),
            onPressed: _busy
                ? null
                : () => _act((i) async => await i.installSystem(prompt: l.cliAdminPrompt(i.systemDir))
                    ? l.cliDoneSystem(i.systemLink)
                    : l.cliCancelledSystem),
            child: Text(l.cliInstallSystem),
          ),
        FilledButton.icon(
          key: const Key('cli-install'),
          onPressed: i == null || _busy || s?.state == CliLinkState.otherFile
              ? null
              : () => _act((i) async {
                    await i.installUser();
                    return l.cliDoneUser(i.userLink, i.cliPath);
                  }),
          icon: const Icon(Icons.download_done_outlined, size: 16),
          label: Text(s?.state == CliLinkState.installed ? l.cliReinstall : l.cliInstall),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (i == null)
          Text(
            l.cliNotBundled,
            style: XText.bodyDim,
          )
        else ...[
          FactRow(l.cliFactApp, appVersionLine),
          FactRow('CLI', i.cliPath),
          FactRow(l.cliFactCommand, i.userLink),
          FactRow(
            l.cliFactNow,
            switch (s?.state) {
              null => '…',
              CliLinkState.absent => l.cliStateAbsent,
              CliLinkState.installed => l.cliStateInstalled,
              CliLinkState.otherLink => l.cliStateOtherLink(s!.currentTarget ?? ''),
              CliLinkState.otherFile => l.cliStateOtherFile,
            },
            valueColor: s?.state == CliLinkState.installed ? XColors.ok : null,
          ),
          if (s != null && s.state == CliLinkState.installed && s.inPath == false) ...[
            const SizedBox(height: 12),
            Text(
              l.cliNotInPath,
              style: XText.bodyDim.copyWith(color: XColors.warn),
            ),
            const SizedBox(height: 8),
            _Cmd(i.pathHint()),
          ],
          if (s != null && s.state == CliLinkState.installed && s.inPath == null) ...[
            const SizedBox(height: 12),
            Text(
              l.cliPathUnknown,
              style: XText.bodyDim,
            ),
            const SizedBox(height: 8),
            _Cmd(i.pathHint()),
          ],
          const SizedBox(height: 12),
          Text(l.cliCheckInNewTerminal, style: XText.bodyDim.copyWith(fontSize: 12)),
          const SizedBox(height: 8),
          const _Cmd('antenna --version && antenna status'),
        ],
        if (_done != null) ...[
          const SizedBox(height: 12),
          Text(_done!, key: const Key('cli-done'), style: XText.bodyDim.copyWith(color: XColors.ok)),
        ],
        if (_error != null) ErrorLine(_error!),
      ]),
    );
  }
}

/// Why the command was not installed, in the app language; paths and stderr as they are.
String describeCliInstallError(AppLocalizations l, CliInstallException e) => switch (e.reason) {
      CliInstallFailure.notBundled => l.cliErrNotBundled(e.path),
      CliInstallFailure.userFileExists => l.cliErrUserFile(e.path),
      CliInstallFailure.macosOnly => l.cliErrMacosOnly,
      CliInstallFailure.systemFileExists => l.cliErrSystemFile(e.path),
      CliInstallFailure.osascript =>
        e.detail.isEmpty ? l.cliErrOsascriptCode(e.exitCode ?? -1) : 'osascript: ${e.detail}',
    };

class _Cmd extends StatelessWidget {
  const _Cmd(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(XRadius.m),
          border: Border.all(color: XColors.line),
          color: XColors.bg0,
        ),
        child: Row(children: [
          Expanded(child: SelectableText(text, style: XText.mono.copyWith(fontSize: 12))),
          IconButton(
            tooltip: context.l.commonCopy,
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            icon: const Icon(Icons.copy_rounded, size: 15),
          ),
        ]),
      );
}
