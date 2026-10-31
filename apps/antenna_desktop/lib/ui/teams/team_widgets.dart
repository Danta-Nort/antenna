// SPDX-License-Identifier: AGPL-3.0-only
// Small pieces of the Teams section (DESIGN "Teams"): the words for the daemon's states, kinds and outcomes, the chips
// that show them, and a button that shows its own progress and result. Every word comes from the daemon's facts: a
// state the window does not know is shown as the daemon's own word, never guessed.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/messages.dart';
import '../../state/teams.dart';
import '../../theme/x_theme.dart';
import '../widgets/x_buttons.dart';

/// The tint a state chip draws its word on (the "Secure" indicator's: 10 % light, 14 % dark, over bg1).
Color teamTint(Color c) => Color.alphaBlend(c.withValues(alpha: XColors.isDark ? 0.14 : 0.10), XColors.bg1);

/// A board column's title.
String columnLabel(AppLocalizations l, BoardColumn c) => switch (c) {
      BoardColumn.open => l.teamColOpen,
      BoardColumn.working => l.teamColWorking,
      BoardColumn.review => l.teamColReview,
      BoardColumn.blocked => l.teamColBlocked,
      BoardColumn.accepted => l.teamColAccepted,
      BoardColumn.applied => l.teamColApplied,
      BoardColumn.cancelled => l.teamColCancelled,
    };

/// A task state in words.
String taskStateLabel(AppLocalizations l, String state) => switch (state) {
      TaskState.open => l.taskStateOpen,
      TaskState.assigned => l.taskStateAssigned,
      TaskState.working => l.taskStateWorking,
      TaskState.blocked => l.taskStateBlocked,
      TaskState.submitted => l.taskStateSubmitted,
      TaskState.returned => l.taskStateReturned,
      TaskState.accepted => l.taskStateAccepted,
      TaskState.done => l.taskStateDone,
      TaskState.cancelled => l.taskStateCancelled,
      _ => state,
    };

Color taskStateColor(String state) => switch (state) {
      TaskState.blocked => XColors.warn,
      TaskState.returned => XColors.warn,
      TaskState.submitted => XColors.accent,
      TaskState.accepted || TaskState.done => XColors.ok,
      TaskState.cancelled => XColors.textMute,
      _ => XColors.textDim,
    };

/// A worker state in words.
String workerStateLabel(AppLocalizations l, String state) => switch (state) {
      WorkerState.idle => l.workerStateIdle,
      WorkerState.starting => l.workerStateStarting,
      WorkerState.busy => l.workerStateBusy,
      WorkerState.sleeping => l.workerStateSleeping,
      WorkerState.stopped => l.workerStateStopped,
      WorkerState.failed => l.workerStateFailed,
      // A local worker waits for its model's runtime.
      'loading' => l.localActivityLoading,
      'waiting' => l.localActivityWaiting,
      _ => state,
    };

Color workerStateColor(String state) => switch (state) {
      WorkerState.busy || WorkerState.starting => XColors.ok,
      WorkerState.failed => XColors.danger,
      WorkerState.stopped => XColors.textMute,
      _ => XColors.textDim,
    };

/// A worker kind in words; a local model names its model.
String workerKindLabel(AppLocalizations l, String kind, {String? model}) => switch (kind) {
      WorkerKind.claude => l.teamKindClaude,
      WorkerKind.program => l.teamKindProgram,
      WorkerKind.codex => l.teamKindCodex,
      WorkerKind.local => model == null ? l.teamKindLocal : l.teamKindLocalModel(model),
      _ => kind,
    };

/// A check's outcome in words.
String checkOutcomeLabel(AppLocalizations l, String outcome) => switch (outcome) {
      'passed' => l.taskCheckOutcomePassed,
      'failed' => l.taskCheckOutcomeFailed,
      'timeout' => l.taskCheckOutcomeTimeout,
      'refused' => l.taskCheckOutcomeRefused,
      'error' => l.taskCheckOutcomeError,
      _ => outcome,
    };

Color checkOutcomeColor(String outcome) => switch (outcome) {
      'passed' => XColors.ok,
      'failed' || 'error' => XColors.danger,
      _ => XColors.warn,
    };

/// Who acted, in words: the owner is "you".
String actorLabel(AppLocalizations l, String by) => switch (by) {
      'owner' => l.teamActorYou,
      'daemon' => l.teamActorDaemon,
      _ => by,
    };

/// A daemon error of a team command in words, with the daemon's own text where it says what exactly.
String describeTeamError(AppLocalizations l, Object e) => switch (e) {
      XControlException(code: XErrorCode.noCapacity, :final message) => l.teamErrNoCapacity(message),
      XControlException(code: XErrorCode.taskState, :final message) => l.teamErrTaskState(message),
      XControlException(code: XErrorCode.mergeConflict, :final message) => l.teamErrMergeConflict(message),
      XControlException(code: XErrorCode.approvalMismatch) => l.teamErrApplyMoved,
      XControlException(code: XErrorCode.approvalRequired) => l.teamErrApprovalRequired,
      XControlException(code: XErrorCode.denied, :final message) => l.teamErrDenied(message),
      XControlException(code: XErrorCode.sandboxUnavailable, :final message) => l.teamErrNoSandbox(message),
      _ => describeError(l, e),
    };

/// A small word on its own tint (a state, an outcome).
class TeamChip extends StatelessWidget {
  const TeamChip(this.text, {super.key, required this.color, this.icon, this.tooltip});
  final String text;
  final Color color;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      decoration: BoxDecoration(color: teamTint(color), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: XText.meta.copyWith(color: color, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }
}

/// The ceiling a task (or a worker) carries, when it limits: below 4 its worker runs no command and no check.
class CeilingChip extends StatelessWidget {
  const CeilingChip(this.level, {super.key, this.compact = false});
  final int level;

  /// Without the shield (a card's narrow row).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final limits = level < 4;
    return TeamChip(
      limits ? l.teamCeilingNoCommands(level) : l.teamCeiling(level),
      key: Key('ceiling-$level'),
      color: limits ? XColors.warn : XColors.textDim,
      icon: compact ? null : Icons.shield_outlined,
      tooltip: l.teamCeilingTip(level),
    );
  }
}

/// A worker's state as a dot.
class WorkerDot extends StatelessWidget {
  const WorkerDot(this.state, {super.key, this.size = 8});
  final String state;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: workerStateColor(state), shape: BoxShape.circle),
      );
}

/// A worker's monogram (a neutral tile with the role's initial; workers carry no AI mark: the daemon runs them).
class WorkerMonogram extends StatelessWidget {
  const WorkerMonogram(this.name, {super.key, this.size = 20});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dot = name.lastIndexOf('.');
    final tail = dot < 0 ? name : name.substring(dot + 1);
    final letter = tail.isEmpty ? '?' : tail.substring(0, 1).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: XColors.bg3, borderRadius: BorderRadius.circular(size / 2)),
      child: Text(letter, style: XText.meta.copyWith(color: XColors.textDim, fontWeight: FontWeight.w600)),
    );
  }
}

enum BusyStyle { filled, outlined, text, destructive }

/// A button whose action runs asynchronously: it shows a spinner while the action runs, is disabled meanwhile, and
/// shows the error the action returns under the screen (a snack bar), so no click goes without visible feedback.
class BusyButton extends StatefulWidget {
  const BusyButton({
    super.key,
    required this.label,
    required this.onRun,
    this.icon,
    this.style = BusyStyle.outlined,
    this.enabled = true,
    this.done,
  });
  final String label;
  final IconData? icon;
  final BusyStyle style;
  final bool enabled;

  /// The action: returns the daemon's error, or `null`.
  final Future<Object?> Function() onRun;

  /// Shown in a snack bar when the action succeeded (`null`: the screen itself shows the result).
  final String? done;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l = context.l;
    Object? err;
    try {
      err = await widget.onRun();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (err != null) {
      messenger?.showSnackBar(SnackBar(content: Text(describeTeamError(l, err))));
    } else if (widget.done case final d?) {
      messenger?.showSnackBar(SnackBar(content: Text(d)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.enabled && !_busy ? _run : null;
    final Widget icon = _busy
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(widget.icon ?? Icons.check_rounded, size: 16);
    final label = Text(widget.label);
    final withIcon = widget.icon != null || _busy;
    return switch (widget.style) {
      BusyStyle.filled =>
        withIcon ? FilledButton.icon(onPressed: onPressed, icon: icon, label: label) : FilledButton(onPressed: onPressed, child: label),
      BusyStyle.outlined => withIcon
          ? OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label)
          : OutlinedButton(onPressed: onPressed, child: label),
      BusyStyle.text =>
        withIcon ? TextButton.icon(onPressed: onPressed, icon: icon, label: label) : TextButton(onPressed: onPressed, child: label),
      BusyStyle.destructive => withIcon
          ? TextButton.icon(onPressed: onPressed, style: XButtons.destructive(), icon: icon, label: label)
          : TextButton(onPressed: onPressed, style: XButtons.destructive(), child: label),
    };
  }
}

/// What a worker does besides writing, in words: a tool it uses (`tool:Bash`), or a local model that loads or waits
/// for memory.
String activityLabel(AppLocalizations l, String activity) => switch (activity) {
      'loading' => l.localActivityLoading,
      'waiting' => l.localActivityWaiting,
      _ when activity.startsWith('tool:') => l.workerUsesTool(activity.substring(5)),
      _ => activity,
    };

/// "3 min ago", "2 h ago", or the date: when a task or a report last changed.
String agoLabel(AppLocalizations l, int ms, DateTime now) {
  if (ms <= 0) return '';
  final d = now.difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return l.teamAgoNow;
  if (d.inMinutes < 60) return l.teamAgoMinutes(d.inMinutes);
  if (d.inHours < 24) return l.teamAgoHours(d.inHours);
  return l.teamAgoDays(d.inDays);
}

/// Tokens in a short form: 182k, 1.2M.
String tokensLabel(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$n';
}
