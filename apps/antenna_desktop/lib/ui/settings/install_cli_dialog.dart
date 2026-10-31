// SPDX-License-Identifier: AGPL-3.0-only
// "Install <app>" from the Check panel (D-110): first the vendor's own command and where it comes from, with nothing
// run until the owner presses Run; then the command in a terminal right in this dialog, where the owner sees all it
// prints and can answer its questions, Stop it, and check again when it has finished.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/l10n.dart';
import '../../state/ai_apps.dart';
import '../../state/cli_installer.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../code/terminal_theme.dart';
import '../widgets/dialog_shell.dart';

/// Show the install dialog for [app] (which has a [AiAppDef.install]).
Future<void> showInstallCliDialog(BuildContext context, AiAppDef app) =>
    showXDialog<void>(context, (_) => _InstallCliDialog(app), dismissible: false);

class _InstallCliDialog extends StatefulWidget {
  const _InstallCliDialog(this.app);
  final AiAppDef app;

  @override
  State<_InstallCliDialog> createState() => _InstallCliDialogState();
}

class _InstallCliDialogState extends State<_InstallCliDialog> {
  CliInstallRun? _run;

  VendorInstall get _install => widget.app.install!;

  @override
  void dispose() {
    _run?.dispose();
    super.dispose();
  }

  void _start() {
    final m = AppScope.read(context);
    final host = m.agentHost;
    if (host == null) return;
    final shell = host.shell;
    final home = host.home;
    final run = CliInstallRun(_install);
    if (shell == null) {
      run
        ..error = const _NoShell()
        ..state = InstallState.failed;
    } else {
      final launch = buildInstallLaunch(
        install: _install,
        shell: shell,
        loginShell: installShell(host.env, shell, exists: host.isFile),
        home: home,
        env: host.env,
        searchDirs: host.programs.searchDirs,
      );
      // The window's log: what ran, never its output.
      debugPrint('antenna/check: the owner ran ${widget.app.name}\'s installer: ${launch.command.join(' ')}');
      run.start(host.startPty, launch);
    }
    run.addListener(_changed);
    setState(() => _run = run);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _close() async {
    final r = _run;
    if (r != null && r.running) await r.stop();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.of(context);
    final r = _run;
    final name = widget.app.name;
    final commandBox = Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: XColors.bg2,
        borderRadius: BorderRadius.circular(XRadius.s),
        border: Border.all(color: XColors.line),
      ),
      child: SelectableText(_install.command,
          key: const Key('check-install-command'), style: XText.mono.copyWith(color: XColors.text)),
    );
    if (r == null) {
      return XDialogShell(
        title: l.checkInstallTitle(name),
        icon: Icons.download_rounded,
        width: 600,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
          OutlinedButton(
            key: const Key('check-install-guide'),
            onPressed: () async {
              if (!await m.openExternal(_install.source)) {
                await Clipboard.setData(ClipboardData(text: _install.source));
              }
            },
            child: Text(l.checkInstallGuide),
          ),
          FilledButton.icon(
            key: const Key('check-install-run'),
            onPressed: m.agentHost == null ? null : _start,
            icon: const Icon(Icons.terminal_rounded, size: 16),
            label: Text(l.checkInstallRun),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.checkInstallAbout(name), style: XText.bodyDim),
          const SizedBox(height: 8),
          commandBox,
          const SizedBox(height: XSpace.s),
          SelectableText(l.checkInstallSource(_install.source, _install.checked),
              key: const Key('check-install-source'), style: XText.meta),
          const SizedBox(height: 8),
          Text(l.checkInstallAfter(name), style: XText.bodyDim),
        ]),
      );
    }
    final status = switch (r.state) {
      InstallState.running => l.checkInstallRunning,
      InstallState.finished when r.exitCode == 0 => l.checkInstallDone(name),
      InstallState.finished => l.checkInstallExited(r.exitCode == null ? '?' : '${r.exitCode}'),
      InstallState.failed => r.error is _NoShell ? l.checkInstallNoShell : l.checkInstallFailed('${r.error}'),
    };
    return XDialogShell(
      title: l.checkInstallTitle(name),
      icon: Icons.download_rounded,
      width: 760,
      actions: [
        if (r.running)
          OutlinedButton(
              key: const Key('check-install-stop'), onPressed: () => unawaited(r.stop()), child: Text(l.checkInstallStop))
        else
          FilledButton(
            key: const Key('check-install-check'),
            onPressed: () async {
              await m.runChecks();
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(l.checkInstallCheck),
          ),
        TextButton(key: const Key('check-install-close'), onPressed: () => unawaited(_close()), child: Text(l.commonClose)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        commandBox,
        const SizedBox(height: 8),
        SizedBox(
          height: 320,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(XRadius.s),
            child: TerminalView(
              r.terminal,
              key: const Key('check-install-terminal'),
              theme: agentTerminalTheme,
              textStyle: agentTerminalStyle,
              padding: const EdgeInsets.all(8),
              autofocus: true,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(status, key: const Key('check-install-status'), style: XText.bodyDim),
      ]),
    );
  }
}

/// No bash, zsh or sh for the wrapper (the screen says it in words).
final class _NoShell implements Exception {
  const _NoShell();
}
