// SPDX-License-Identifier: AGPL-3.0-only
// The Check panel (D-96 phase 1, D-UI-26): every check with its result and, for a problem, the fix as a button. In
// Settings → Check, and as a dialog from the sign-in screen and the daemon details. Each fix is the owner's action:
// the daemon's existing owner commands (unlock, sign in, the local network) or a local action shown before it runs
// (the shell profile line, an app's own Quit, the Screen Recording pane of System Settings). The checks themselves
// are in state/doctor.dart.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../host/shell_path.dart';
import '../../l10n/l10n.dart';
import '../../state/agent_launch.dart' show AgentCli;
import '../../state/doctor.dart';
import '../../state/format.dart';
import '../../state/messages.dart';
import '../../state/touch_id.dart';
import '../../theme/x_theme.dart';
import '../agents/agents_dialog.dart';
import '../app_scope.dart';
import '../code/screen_permission_sheet.dart';
import '../code/start_agent_dialog.dart';
import '../gate/gate_screen.dart' show describeDaemonStart;
import '../security/owner_confirm.dart';
import '../security/touch_id_text.dart';
import '../widgets/dialog_shell.dart';
import 'install_cli_dialog.dart';

/// The panel as a dialog (from an error state).
Future<void> showCheckDialog(BuildContext context) => showXDialog<void>(
      context,
      (ctx) => XDialogShell(
        title: ctx.l.checkTitle,
        icon: Icons.fact_check_outlined,
        width: 680,
        child: const CheckPanel(dialog: true),
      ),
    );

class CheckPanel extends StatefulWidget {
  const CheckPanel({super.key, this.dialog = false});

  /// Inside a dialog (no title of its own).
  final bool dialog;

  @override
  State<CheckPanel> createState() => _CheckPanelState();
}

class _CheckPanelState extends State<CheckPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(AppScope.read(context).runChecks());
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final at = m.checkedAt;
    return Column(key: const Key('check-panel'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(l.checkAbout, style: XText.bodyDim)),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          key: const Key('check-again'),
          onPressed: m.checking ? null : () => unawaited(m.runChecks()),
          icon: m.checking
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh_rounded, size: 16),
          label: Text(l.checkAgain),
        ),
      ]),
      if (at != null) ...[
        const SizedBox(height: 4),
        Text(l.checkCheckedAt(hhmm(at)), style: XText.meta),
      ],
      const SizedBox(height: 16),
      for (final c in m.checks) _Row(c),
    ]);
  }
}

class _Row extends StatelessWidget {
  const _Row(this.c);
  final Check c;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final (icon, color) = switch (c.state) {
      CheckState.ok => (Icons.check_circle_rounded, XColors.ok),
      CheckState.problem => (Icons.error_rounded, XColors.danger),
      CheckState.info => (Icons.info_outline_rounded, XColors.textMute),
      CheckState.unknown => (Icons.help_outline_rounded, XColors.textMute),
    };
    final (key, title, body) = _content(context, c);
    return Container(
      key: Key('check-row-$key'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: XColors.bg1,
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(color: c.state == CheckState.problem ? XColors.danger.withValues(alpha: 0.45) : XColors.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: color)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(title, style: XText.title.copyWith(fontSize: 14))),
              if (c.code case final code?) Text(code, style: XText.monoSmall),
            ]),
            const SizedBox(height: 4),
            ...body,
            if (c.state == CheckState.problem || c.state == CheckState.info) ..._fixes(context, c, l),
          ]),
        ),
      ]),
    );
  }
}

Widget _text(String s, {Key? key}) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: SelectableText(s, key: key, style: XText.bodyDim),
    );

Widget _mono(String s) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SelectableText(s, style: XText.monoSmall.copyWith(color: XColors.textDim)),
    );

String _why(AppLocalizations l, UnknownReason? r) => switch (r) {
      UnknownReason.noDaemon => l.checkUnknownNoDaemon,
      UnknownReason.locked => l.checkUnknownLocked,
      UnknownReason.olderDaemon => l.checkUnknownOlderDaemon,
      UnknownReason.noLoginShell => l.checkUnknownLoginShell,
      null => '',
    };

/// The row's key, title and text.
(String, String, List<Widget>) _content(BuildContext context, Check c) {
  final l = context.l;
  return switch (c) {
    DaemonCheck() => (
        'daemon',
        l.checkDaemonTitle,
        [
          _text(switch (c.state) {
            CheckState.ok => l.checkDaemonOk([c.daemon, c.protocol].whereType<String>().join(' · ')),
            CheckState.problem => c.canStart ? l.checkDaemonDown : l.checkDaemonDownExternal(c.socket),
            _ => l.checkDaemonConnecting,
          }),
          if (c.error case final e?) ...[
            _text(e.exitCode == null ? describeDaemonStart(l, e) : l.gateErrorWithExitCode(describeDaemonStart(l, e), e.exitCode!)),
            if (e.logTail.isNotEmpty) _mono(e.logTail),
          ],
        ]
      ),
    KeysCheck() => (
        'keys',
        l.checkKeysTitle,
        [
          _text(switch (c.state) {
            CheckState.ok => l.checkKeysOk,
            CheckState.problem => c.signIn ? l.checkKeysSignIn : l.checkKeysLocked,
            CheckState.info => l.checkKeysNew,
            CheckState.unknown => l.checkUnknownNoDaemon,
          }),
        ]
      ),
    RelayCheck() => (
        'relay',
        l.checkRelayTitle,
        [
          _text(switch (c.state) {
            CheckState.ok => c.connected == 0
                ? l.checkRelayNoLinks(c.setting ?? '—')
                : l.checkRelayOk(c.connected, c.setting ?? '—'),
            CheckState.problem => c.disabled ? l.checkRelayDisabled(c.relayOnlyContacts) : l.checkRelayDown(c.down.length),
            CheckState.info => l.checkRelayDisabledInfo,
            CheckState.unknown => _why(l, c.reason),
          }),
          for (final d in c.down)
            _mono([
              '${d.contact} · ${l.checkLevel(d.trust)}${d.relayOnly ? ' · ${l.checkRelayOnly}' : ''}',
              d.url.isEmpty ? l.checkRelayNoHome : d.url,
              ?d.error,
            ].join('\n')),
          if (c.state == CheckState.problem || c.state == CheckState.unknown)
            _CopyLine(label: l.checkDoctorCli, value: 'antenna doctor'),
        ]
      ),
    CliCheck() => (
        'cli-${c.app.id.name}',
        l.checkCliTitle(c.app.name),
        [
          _text(switch (c.state) {
            CheckState.ok => l.checkCliOk(c.path!),
            CheckState.problem when c.missing => l.checkCliMissing,
            CheckState.problem => l.checkCliNotOnPath(c.path!, c.folder!),
            CheckState.info => l.checkCliMissingInfo(c.app.name),
            CheckState.unknown => l.checkCliUnknown(c.path ?? '—'),
          }),
          if (c.missing) _mono(l.checkCliSearched(c.searched.join('\n'))),
          if (!c.missing && c.state == CheckState.problem && c.fix == null) _text(l.checkCliPathByHand(c.folder!)),
        ]
      ),
    AppRestartCheck() => ('restart-${c.app.id.name}', l.checkRestartTitle(c.app.name), [_text(l.checkRestartAbout(c.app.name))]),
    // The same fix as the sheet before a screenshot (D-UI-41): the steps and the button that opens the pane.
    ScreenRecordingCheck() => (
        'screen-recording',
        l.screenPermissionCheckTitle,
        [
          _text(switch (c.state) {
            CheckState.ok => l.screenPermissionCheckOk,
            CheckState.problem || CheckState.info => l.screenPermissionCheckMissing,
            CheckState.unknown => l.screenPermissionCheckUnknown,
          }),
          if (c.state == CheckState.problem || c.state == CheckState.info) ...[
            const SizedBox(height: 8),
            const ScreenPermissionFix(),
          ],
        ]
      ),
    TokenCheck() => (
        'tokens',
        l.checkTokensTitle,
        [
          if (c.state == CheckState.ok) _text(l.checkTokensOk),
          if (c.state == CheckState.unknown) _text(_why(l, c.reason)),
          for (final r in c.refusals)
            _text(
              l.checkTokenRefused(
                r.agent,
                r.boundComm == null ? l.checkTokenNobody : '${r.boundComm} (pid ${r.boundPid})',
                '${r.refusedComm.isEmpty ? '?' : r.refusedComm} (pid ${r.refusedPid})',
                hhmm(r.at),
              ),
              key: Key('check-refusal-${r.agent}'),
            ),
          if (c.refusals.isNotEmpty) _text(l.checkTokenWhy),
        ]
      ),
  };
}

/// A command to copy (the same report in a terminal).
class _CopyLine extends StatelessWidget {
  const _CopyLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          Text(label, style: XText.meta),
          const SizedBox(width: 8),
          SelectableText(value, style: XText.monoSmall.copyWith(color: XColors.text)),
          IconButton(
            tooltip: context.l.commonCopy,
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            icon: const Icon(Icons.copy_rounded),
          ),
        ]),
      );
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

/// The fix buttons of a row.
List<Widget> _fixes(BuildContext context, Check c, AppLocalizations l) {
  final m = AppScope.read(context);
  Widget button(String key, String label, IconData icon, Future<void> Function() run, {bool primary = true}) =>
      (primary ? FilledButton.icon : OutlinedButton.icon)(
        key: Key('check-fix-$key'),
        onPressed: () => unawaited(run()),
        icon: Icon(icon, size: 16),
        label: Text(label),
      );
  final buttons = <Widget>[
    ...switch (c) {
      DaemonCheck(canStart: true) => [
          button('start', l.checkFixStart, Icons.play_arrow_rounded, () async {
            await m.startDaemon();
            await m.runChecks();
          }),
        ],
      KeysCheck(state: CheckState.problem) => [
          button(c.signIn ? 'signin' : 'unlock', c.signIn ? l.checkFixSignIn : l.checkFixUnlock, Icons.lock_open_rounded,
              () async {
            // One touch first when Touch ID can do it (the unlock slot, or a proof for the sign-in), D-131.
            String? note;
            if (c.signIn ? m.touchIdReady : m.touchIdUnlockReady) {
              final err = c.signIn
                  ? await m.signInWithTouchId(reason: l.touchIdReasonSignIn)
                  : await m.unlockWithTouchId(reason: l.touchIdReasonUnlock);
              if (err == null || TouchIdMixin.fallbackFor(err) == TouchIdFallback.none) {
                if (err != null && context.mounted) _snack(context, describeError(l, err));
                await m.runChecks();
                return;
              }
              note = touchIdFallbackNote(l, m, err);
              if (!context.mounted) return;
            }
            final pw = await askOwnerPassword(context, action: c.signIn ? l.checkFixSignIn : l.checkFixUnlock, note: note);
            if (pw == null || pw.isEmpty) return;
            final err = c.signIn ? await m.login(pw) : await m.unlock(pw);
            if (err != null && context.mounted) _snack(context, describeError(l, err));
            await m.runChecks();
          }),
        ],
      // The local network serves contacts at level 3+ only (D-77).
      RelayCheck(disabled: false, state: CheckState.problem)
          when m.lanSupported && !(m.lan?.enabled ?? true) && c.down.any((d) => !d.relayOnly) =>
        [
          button('lan', l.checkFixLan, Icons.wifi_rounded, () async {
            final (_, err) = await confirmOwner(context,
                action: l.checkFixLan, detail: l.checkFixLanDetail, run: (auth) => m.setLan(enabled: true, auth: auth));
            if (err != null && context.mounted) _snack(context, describeError(l, err));
            await m.runChecks();
          }, primary: false),
        ],
      CliCheck(missing: true) when c.app.installUrl != null => [
          // The vendor's own command, shown first and run in a terminal in the window after the owner's Run (D-110)
          if (c.app.install != null && m.agentHost != null)
            button('run-install-${c.app.id.name}', l.checkFixInstallRun(c.app.name), Icons.download_rounded,
                () => showInstallCliDialog(context, c.app),
                primary: c.state == CheckState.problem),
          button('install-${c.app.id.name}', l.checkFixInstall(c.app.name), Icons.open_in_new_rounded, () async {
            final url = c.app.installUrl!;
            if (!await m.openExternal(url)) {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) _snack(context, l.checkLinkCopied(url));
            }
          }, primary: c.state == CheckState.problem && (c.app.install == null || m.agentHost == null)),
        ],
      CliCheck(:final fix?) => [
          button('path-${c.app.id.name}', l.checkFixPath(c.folder!), Icons.terminal_rounded, () async {
            if (await _confirmPath(context, c, fix) != true) return;
            try {
              final (r, backup) = await m.applyPathFixAndCheck(fix);
              if (!context.mounted) return;
              _snack(
                  context,
                  r == PathFixResult.present
                      ? l.checkPathPresent(fix.profile)
                      : backup == null
                          ? l.checkPathAdded(fix.profile)
                          : l.checkPathAddedBackup(fix.profile, backup));
            } on Object catch (e) {
              if (context.mounted) _snack(context, l.checkPathFailed(fix.profile, '$e'));
            }
          }),
        ],
      AppRestartCheck() => [
          button('restart-${c.app.id.name}', l.checkFixRestart(c.app.name), Icons.restart_alt_rounded, () async {
            if (await _confirmRestart(context, c) != true) return;
            if (!await m.restartApp(c) && context.mounted) _snack(context, l.checkRestartFailed(c.app.name));
          }),
        ],
      TokenCheck() => [
          for (final r in c.refusals)
            if (r.cli case final cli?)
              button('newagent-${r.agent}', l.checkFixNewAgent(cli == AgentCli.claude ? 'Claude Code' : 'Codex'),
                  Icons.add_rounded, () => showStartAgentDialog(context, cli: cli, newAgent: true))
            else
              button('apps-${r.agent}', l.checkFixApps, Icons.smart_toy_outlined, () => showAgentsDialog(context),
                  primary: false),
        ],
      _ => const <Widget>[],
    },
  ];
  if (buttons.isEmpty) return const [];
  return [
    const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 8, children: buttons),
  ];
}

/// The PATH line, shown before it is written.
Future<bool?> _confirmPath(BuildContext context, CliCheck c, PathFix fix) {
  final l = context.l;
  return showXDialog<bool>(
    context,
    (ctx) => XDialogShell(
      title: l.checkPathConfirmTitle(fix.folder),
      icon: Icons.terminal_rounded,
      width: 560,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.commonCancel)),
        FilledButton(
            key: const Key('check-path-ok'), onPressed: () => Navigator.pop(ctx, true), child: Text(l.checkPathConfirmOk)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.checkPathConfirmAbout(fix.profile), style: XText.bodyDim),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: XColors.bg2,
            borderRadius: BorderRadius.circular(XRadius.s),
            border: Border.all(color: XColors.line),
          ),
          child: SelectableText(
            '# Added by Antenna: ${fix.folder} on PATH for new terminals\n${fix.line}',
            key: const Key('check-path-line'),
            style: XText.mono.copyWith(color: XColors.text),
          ),
        ),
        const SizedBox(height: 8),
        Text(l.checkPathConfirmAfter(c.app.name), style: XText.bodyDim),
      ]),
    ),
  );
}

/// Restarting an app may lose its unsaved work: asked first.
Future<bool?> _confirmRestart(BuildContext context, AppRestartCheck c) {
  final l = context.l;
  return showXDialog<bool>(
    context,
    (ctx) => XDialogShell(
      title: l.checkRestartConfirmTitle(c.app.name),
      icon: Icons.restart_alt_rounded,
      width: 480,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.commonCancel)),
        FilledButton(
            key: const Key('check-restart-ok'), onPressed: () => Navigator.pop(ctx, true), child: Text(l.checkRestartOk)),
      ],
      child: Text(l.checkRestartConfirmAbout(c.app.name), style: XText.bodyDim),
    ),
  );
}
