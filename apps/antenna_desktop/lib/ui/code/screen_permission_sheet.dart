// SPDX-License-Identifier: AGPL-3.0-only
// The window's own explanation when macOS has not given this build Screen Recording (D-UI-41): shown before the
// screenshot tool runs, instead of macOS's question over the tool and a picture of the desktop. It says why (macOS keeps
// the permission per build until the app is signed with a Developer ID), the exact fix, a button that opens the pane,
// and "Try again", which checks again and asks macOS once before the tool runs. The same fix is the Screen Recording
// row of Settings → Check.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../host/screen_permission.dart';
import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/dialog_shell.dart';

/// The sheet; `true` when the owner pressed "Try again". [retried]: the last try found the permission still missing.
Future<bool?> showScreenPermissionSheet(BuildContext context, {bool retried = false}) => showXDialog<bool>(
      context,
      (ctx) => XDialogShell(
        key: const Key('screen-permission-sheet'),
        title: ctx.l.screenPermissionTitle,
        icon: Icons.screenshot_monitor_outlined,
        width: 600,
        actions: [
          TextButton(
            key: const Key('screen-permission-close'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l.commonClose),
          ),
          FilledButton.icon(
            key: const Key('screen-permission-retry'),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(ctx.l.screenPermissionTryAgain),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          if (retried) ...[
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.info_outline_rounded, size: 18, color: XColors.warn),
              ),
              const SizedBox(width: 8),
              Expanded(
                  child:
                      Text(ctx.l.screenPermissionStill, key: const Key('screen-permission-still'), style: XText.body)),
            ]),
            const SizedBox(height: 12),
          ],
          Text(ctx.l.screenPermissionWhat, style: XText.bodyDim),
          const SizedBox(height: 16),
          const ScreenPermissionFix(),
        ]),
      ),
    );

/// The steps and the button that opens the pane: in the sheet and in the Check row.
class ScreenPermissionFix extends StatefulWidget {
  const ScreenPermissionFix({super.key});

  @override
  State<ScreenPermissionFix> createState() => _ScreenPermissionFixState();
}

class _ScreenPermissionFixState extends State<ScreenPermissionFix> {
  bool _openFailed = false;

  Future<void> _open() async {
    final ok = await AppScope.read(context).openExternal(screenRecordingSettingsUrl);
    if (mounted) setState(() => _openFailed = !ok);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final steps = [l.screenPermissionStep1, l.screenPermissionStep2, l.screenPermissionStep3, l.screenPermissionStep4];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < steps.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 20, child: Text('${i + 1}.', style: XText.bodyDim)),
            Expanded(child: SelectableText(steps[i], style: XText.bodyDim)),
          ]),
        ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const Key('screen-permission-open'),
          onPressed: () => unawaited(_open()),
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          label: Text(l.screenPermissionOpen),
        ),
      ),
      if (_openFailed) ...[
        const SizedBox(height: 4),
        Text(l.screenPermissionOpenFailed, key: const Key('screen-permission-open-failed'), style: XText.meta),
      ],
    ]);
  }
}
