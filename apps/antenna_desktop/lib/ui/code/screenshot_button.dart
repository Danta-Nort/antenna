// SPDX-License-Identifier: AGPL-3.0-only
// "Screenshot" next to the quick replies under a Code mode terminal (D-UI-27, code_shot.dart): the owner picks an area
// or a window; Claude Code gets the image in its prompt, other programs get nothing typed and the owner the file's
// path. Shown only where the system has a screenshot tool.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_launch.dart' show AgentCli;
import '../../state/code_mode.dart';
import '../../state/code_shot.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import 'screen_permission_sheet.dart';

/// The button (`null`-sized when this computer has no screenshot tool).
class ShotButton extends StatelessWidget {
  const ShotButton(this.r, {super.key, required this.style});
  final AgentRun r;
  final ButtonStyle style;

  Future<void> _take(BuildContext context) async {
    final m = AppScope.read(context);
    final l = context.l;
    final messenger = ScaffoldMessenger.maybeOf(context);
    var res = await m.takeScreenshot(r);
    // No Screen Recording for this build (macOS): the window's explanation first, the tool only after "Try again"
    // finds the permission (D-UI-41).
    for (var retried = false; res.outcome == ShotOutcome.needsPermission; retried = true) {
      if (!context.mounted || await showScreenPermissionSheet(context, retried: retried) != true) return;
      res = await m.takeScreenshot(r, ask: true);
    }
    final text = switch (res.outcome) {
      ShotOutcome.attached => l.codeShotAttached,
      ShotOutcome.failed => l.codeShotFailed,
      _ => null,
    };
    if (text != null) messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    if (!m.screenshotsAvailable) return const SizedBox.shrink();
    final busy = m.capturing(r);
    return Tooltip(
      message: r.spec.cli == AgentCli.claude ? l.codeShotTipClaude : l.codeShotTipOther,
      child: OutlinedButton.icon(
        key: const Key('code-shot'),
        style: style,
        onPressed: busy ? null : () => unawaited(_take(context)),
        icon: busy
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.screenshot_monitor_outlined, size: 16),
        label: Text(l.codeShot),
      ),
    );
  }
}

/// Under the buttons: a screenshot waiting for the prompt (with Cancel), or one kept with its path (with Copy).
class ShotNote extends StatelessWidget {
  const ShotNote(this.r, {super.key});
  final AgentRun r;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final waiting = m.waitingShot(r);
    final kept = m.keptShots[r.id];
    if (waiting == null && kept == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Icon(Icons.screenshot_monitor_outlined, size: 14, color: XColors.textMute),
        const SizedBox(width: 8),
        Expanded(
          child: waiting != null
              ? Text(l.codeShotWaiting, key: const Key('code-shot-waiting'), style: XText.meta)
              : SelectableText(
                  r.spec.cli == AgentCli.claude ? l.codeShotKept(kept!.path) : l.codeShotSaved(kept!.path),
                  key: const Key('code-shot-kept'),
                  style: XText.meta),
        ),
        if (waiting != null)
          TextButton(
            key: const Key('code-shot-cancel'),
            onPressed: () => m.cancelWaitingShot(r),
            child: Text(l.commonCancel),
          )
        else ...[
          IconButton(
            key: const Key('code-shot-copy'),
            tooltip: l.codeShotCopy,
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: () => Clipboard.setData(ClipboardData(text: kept!.path)),
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            key: const Key('code-shot-dismiss'),
            tooltip: l.commonClose,
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: () => m.dismissKeptShot(r),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ]),
    );
  }
}
