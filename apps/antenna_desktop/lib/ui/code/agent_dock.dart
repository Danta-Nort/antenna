// SPDX-License-Identifier: AGPL-3.0-only
// Code mode: the agents' terminals on the right of the window. One tab per running agent; each tab is a real terminal
// (xterm) on a pseudo-terminal the window started, with the agent's status and Restart / Stop. The dock can be
// resized by dragging its left edge and folded to a narrow strip. Under a running agent's terminal, quick replies type
// fixed lines on the owner's click; the tab's menu holds "Wake on new messages" (code_wake.dart, D-UI-23). The
// workers the daemon runs for a team (cloud CLIs) follow as read-only tabs: their live output, never a terminal to
// type into (teams/worker_view.dart).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_launch.dart' show AgentCli;
import '../../state/code_mode.dart';
import '../../state/code_wake.dart';
import '../../state/format.dart';
import '../../theme/x_theme.dart';
import '../agents/agent_stop_dialog.dart';
import '../app_scope.dart';
import '../teams/worker_view.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/x_buttons.dart';
import 'agent_terminal.dart';
import 'code_text.dart';
import 'screenshot_button.dart';
import 'start_agent_dialog.dart';

/// Width of the folded dock.
const dockStripWidth = 48.0;

/// The narrowest dock, and the room the chats need next to it: the list (300) and a conversation of at least 500.
const dockMinWidth = 380.0;
const dockMinContent = 800.0;

/// The dock's width for the space right of the navigation, or `null` when only the strip fits.
double? dockWidthFor(double available, double wanted) {
  final max = available - dockMinContent;
  if (max < dockMinWidth) return null;
  return wanted.clamp(dockMinWidth, max);
}

class AgentDock extends StatelessWidget {
  const AgentDock({super.key, this.folded = false});

  /// Folded by the window's width (the owner's own choice is `dockCollapsed`).
  final bool folded;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    if (folded || m.dockCollapsed) return _Strip(canExpand: !folded);
    final run = m.activeRun;
    final worker = m.dockWorker;
    return Container(
      key: const Key('agent-dock'),
      color: XColors.bg1,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _TabBar(),
        Divider(height: 1, color: XColors.line),
        if (worker != null && m.teamOfWorker(worker) != null)
          Expanded(child: WorkerDockView(worker, key: ValueKey('worker-$worker')))
        else if (run == null)
          const Expanded(child: _Empty())
        else ...[
          _RunBar(run, key: ValueKey('bar-${run.id}')),
          Expanded(child: AgentTerminal(run, key: ValueKey('screen-${run.id}'))),
          QuickReplyBar(run, key: ValueKey('quick-${run.id}')),
        ],
      ]),
    );
  }
}

/// The dock's left edge: drag to resize.
class DockHandle extends StatelessWidget {
  const DockHandle({super.key, required this.onDrag});
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          key: const Key('dock-handle'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
          child: SizedBox(
            width: 7,
            child: Center(child: Container(width: 1, color: XColors.line)),
          ),
        ),
      );
}

Color _dot(AgentRun r) => switch (r.state) {
      AgentRunState.running => XColors.ok,
      AgentRunState.stopping => XColors.warn,
      AgentRunState.failed => XColors.danger,
      AgentRunState.exited => r.stoppedByOwner || r.exitCode == 0 ? XColors.textMute : XColors.danger,
    };

Future<void> _restart(BuildContext context, AgentRun r) async {
  final m = AppScope.read(context);
  final l = context.l;
  final err = await m.restartRun(r);
  if (!context.mounted || err == null) return;
  if (err is AgentNeedsPassword) {
    await showStartAgentDialog(context, spec: r.spec);
    return;
  }
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeCodeError(l, err))));
}

class _TabBar extends StatelessWidget {
  const _TabBar();

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    return Container(
      height: 48,
      color: XColors.nav,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Row(children: [
        Icon(Icons.terminal_rounded, size: 17, color: XColors.textDim),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final r in m.runs) _Tab(r, selected: identical(r, m.activeRun) && m.dockWorker == null),
              for (final w in m.dockWorkers) WorkerDockTab(w, selected: m.dockWorker == w.name),
            ]),
          ),
        ),
        IconButton(
          key: const Key('code-start'),
          tooltip: l.codeStartAgent,
          onPressed: () => showStartAgentDialog(context),
          icon: const Icon(Icons.add_rounded, size: 20),
        ),
        IconButton(
          key: const Key('code-collapse'),
          tooltip: l.codeHideDock,
          onPressed: () => m.setDock(collapsed: true),
          icon: const Icon(Icons.keyboard_double_arrow_right_rounded, size: 20),
        ),
      ]),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab(this.r, {required this.selected});
  final AgentRun r;
  final bool selected;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: r,
        builder: (context, _) {
          final m = AppScope.read(context);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Material(
              color: selected ? XColors.bg1 : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(XRadius.m),
                side: BorderSide(color: selected ? XColors.lineStrong : Colors.transparent),
              ),
              child: InkWell(
                key: Key('code-tab-${r.spec.agent}'),
                borderRadius: BorderRadius.circular(XRadius.m),
                onTap: () {
                  m.showWorkerInDock(null);
                  m.selectRun(r);
                },
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, 8, r.alive ? 12 : 4, 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: _dot(r), shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(
                      r.spec.agent,
                      style: XText.label.copyWith(color: selected ? XColors.text : XColors.textDim),
                    ),
                    if (!r.alive)
                      InkWell(
                        key: Key('code-close-${r.spec.agent}'),
                        onTap: () => m.closeRun(r),
                        borderRadius: BorderRadius.circular(XRadius.s),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded, size: 14, color: XColors.textMute),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          );
        },
      );
}

/// Who runs in the tab, where, and how it is doing; Restart and Stop.
class _RunBar extends StatelessWidget {
  const _RunBar(this.r, {super.key});
  final AgentRun r;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: r,
        builder: (context, _) {
          final m = AppScope.read(context);
          final l = context.l;
          final home = m.agentHost?.home ?? '';
          final status = runStateText(l, r);
          return Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            decoration: BoxDecoration(color: XColors.bg1, border: Border(bottom: BorderSide(color: XColors.line))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Who and how it is doing on the first line; where, and the actions, on the second.
              Row(children: [
                Expanded(
                  child: Text('${r.spec.agent} · ${programName(l, r.spec.cli)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: XText.title.copyWith(fontSize: 14)),
                ),
                const SizedBox(width: 8),
                Container(width: 8, height: 8, decoration: BoxDecoration(color: _dot(r), shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text(status, key: const Key('code-status'), style: XText.meta.copyWith(color: XColors.textDim)),
                const SizedBox(width: 8),
              ]),
              Row(children: [
                Expanded(
                  child: Text(
                    shortFolder(r.spec.workDir, home),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: XText.monoSmall,
                  ),
                ),
                if (r.state != AgentRunState.stopping)
                  TextButton.icon(
                    key: const Key('code-restart'),
                    onPressed: () => _restart(context, r),
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: Text(l.codeRestart),
                  ),
                if (r.alive)
                  TextButton.icon(
                    key: const Key('code-stop'),
                    onPressed: r.state == AgentRunState.running ? () => m.stopRun(r) : null,
                    style: XButtons.destructive(),
                    icon: const Icon(Icons.stop_rounded, size: 16),
                    label: Text(l.codeStop),
                  ),
                _RunMenu(r),
              ]),
              if (r.error case final e?) ...[
                Text(describeCodeError(l, e), style: XText.bodyDim.copyWith(color: XColors.danger, fontSize: 12)),
                const SizedBox(height: 4),
              ],
            ]),
          );
        },
      );
}

enum _MenuItem { wake, restore, stopAll }

/// The tab's menu: "Wake on new messages" and "Restore after an update" (both on by default; the window settings file
/// keeps them), and "Stop agent and its processes…" (CONTROL §33), next to the tab's own Stop, which stops only its
/// terminal.
class _RunMenu extends StatelessWidget {
  const _RunMenu(this.r);
  final AgentRun r;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final agent = r.spec.agent;
    final wake = m.codeWakeOn(agent);
    final restore = m.codeRestoreOn(agent);
    // An own command has no session to resume.
    final canRestore = r.spec.cli != AgentCli.custom && m.agentRunStore != null;
    Widget item(String title, String hint, Key tag, {Color? color}) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            // Mechanisms of our own (D-94): marked experimental here, their controls in the dock.
            Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(title, style: XText.label.copyWith(color: color ?? XColors.text)),
              ExperimentalTag(key: tag),
            ]),
            const SizedBox(height: 2),
            Text(hint, style: XText.meta),
          ]),
        );
    return PopupMenuButton<_MenuItem>(
      key: const Key('code-menu'),
      tooltip: l.codeMenu,
      icon: Icon(Icons.more_vert_rounded, size: 18, color: XColors.textDim),
      onSelected: (v) {
        switch (v) {
          case _MenuItem.wake:
            m.setCodeWake(agent, !wake);
          case _MenuItem.restore:
            m.setCodeRestore(agent, !restore);
          case _MenuItem.stopAll:
            unawaited(stopAgentWithConfirm(context, agent));
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem<_MenuItem>(
          key: const Key('code-wake-toggle'),
          value: _MenuItem.wake,
          checked: wake,
          child: item(l.codeWakeSwitch, l.codeWakeSwitchHint, const Key('experimental-code-wake')),
        ),
        if (canRestore)
          CheckedPopupMenuItem<_MenuItem>(
            key: const Key('code-restore-toggle'),
            value: _MenuItem.restore,
            checked: restore,
            child: item(l.codeRestoreSwitch, l.codeRestoreSwitchHint, const Key('experimental-code-restore')),
          ),
        if (r.alive) ...[
          const PopupMenuDivider(),
          PopupMenuItem<_MenuItem>(
            key: const Key('code-stop-all'),
            value: _MenuItem.stopAll,
            child: item(l.agentStopAction, l.agentStopHint, const Key('experimental-code-stop-all'),
                color: XColors.danger),
          ),
        ],
      ],
    );
  }
}

/// Under a running agent's terminal: fixed replies on the owner's click, and what the window last typed by itself.
class QuickReplyBar extends StatelessWidget {
  const QuickReplyBar(this.r, {super.key});
  final AgentRun r;

  static String label(AppLocalizations l, QuickReply q) => switch (q) {
        QuickReply.approved => l.codeQuickApproved,
        QuickReply.checkChat => l.codeQuickCheckChat,
        QuickReply.goAhead => l.codeQuickGoAhead,
        QuickReply.stop => l.codeQuickStop,
      };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: r,
        builder: (context, _) {
          if (!r.alive) return const SizedBox.shrink();
          final m = AppScope.of(context);
          final l = context.l;
          final last = m.lastCodeLine(r.spec.agent);
          final urgent = m.urgentWait(r);
          final note = m.codeWakeUnavailable(r)
              ? (r.spec.cli == AgentCli.codex ? l.codeWakeUnavailableCodex : l.codeWakeUnavailable)
              : urgent != null
              ? urgentNote(l, urgent)
              : m.updateLinePending(r)
              ? l.codeUpdateWaiting
              : m.codeLinePending(r)
              ? l.codeWakeWaiting
              : switch (last) {
                  null => null,
                  CodeLineEntry(kind: CodeLineKind.approved) => l.codeApprovedTyped(hhmm(last.at)),
                  CodeLineEntry(kind: CodeLineKind.updated) => l.codeUpdatedTyped(hhmm(last.at)),
                  CodeLineEntry(kind: CodeLineKind.toAnswer) => l.codeToAnswerTyped(hhmm(last.at)),
                  CodeLineEntry(kind: CodeLineKind.urgent, :final contact, :final interrupt, :final interruptedAt) =>
                    interrupt || interruptedAt != null
                        ? l.codeUrgentInterrupted(hhmm(interruptedAt ?? last.at), contact ?? l.codeUrgentSeveral)
                        : l.codeUrgentTyped(hhmm(last.at), contact ?? l.codeUrgentSeveral),
                  CodeLineEntry(:final contact?) => l.codeWokeFrom(hhmm(last.at), contact),
                  _ => l.codeWokeAny(hhmm(last.at)),
                };
          // Restored after an automatic update (D-103): said once, with what that meant before sign-in.
          final restored = r.restoredTo == null
              ? null
              : [
                  l.codeRestoredNote(sanitizeVersion(r.restoredTo!)),
                  if (r.watchUnavailable) l.codeWatchUnavailable,
                ].join(' · ');
          final style = XButtons.secondary().copyWith(
            minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
            padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
            textStyle: const WidgetStatePropertyAll(
                TextStyle(fontFamily: XFonts.sans, fontWeight: FontWeight.w500, fontSize: 12)),
          );
          return Container(
            key: const Key('code-quick-bar'),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(color: XColors.bg1, border: Border(top: BorderSide(color: XColors.line))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final q in QuickReply.values)
                  Tooltip(
                    message: q.line == null ? l.codeQuickStopTip : l.codeQuickTypes(q.line!.text),
                    child: OutlinedButton(
                      key: Key('code-quick-${q.name}'),
                      style: q == QuickReply.stop
                          ? style.copyWith(foregroundColor: WidgetStatePropertyAll(XColors.danger))
                          : style,
                      onPressed: () => m.quickReply(r, q),
                      child: Text(label(l, q)),
                    ),
                  ),
                ShotButton(r, style: style),
              ]),
              ShotNote(r),
              if (restored != null) ...[
                const SizedBox(height: 8),
                Text(restored, key: const Key('code-restored-note'), style: XText.meta.copyWith(color: XColors.accent)),
              ],
              if (note != null) ...[
                const SizedBox(height: 8),
                Text(note, key: const Key('code-wake-note'), style: XText.meta),
              ],
            ]),
          );
        },
      );
}

/// The dock's note while an urgent message waits for an agent (CONTROL §33): interrupted, or why not yet.
String urgentNote(AppLocalizations l, UrgentWait u) {
  final who = u.contact ?? l.codeUrgentSeveral;
  if (u.interruptedAt case final at?) return l.codeUrgentInterrupted(hhmm(at), who);
  return switch (u.block) {
    InterruptBlock.dialog => l.codeUrgentWaitDialog(who),
    InterruptBlock.draft => l.codeUrgentWaitDraft(who),
    InterruptBlock.tooSoon => l.codeUrgentWaitSoon(who),
    _ => l.codeUrgentWaitPrompt(who),
  };
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
              child: Icon(Icons.terminal_rounded, size: 22, color: XColors.accent),
            ),
            const SizedBox(height: 16),
            Text(l.codeEmptyTitle, style: XText.title, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(l.codeEmptyBody, style: XText.bodyDim, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('code-start-empty'),
              onPressed: () => showStartAgentDialog(context),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(l.codeStartAgent),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The folded dock: a dot per agent, expand and start.
class _Strip extends StatelessWidget {
  const _Strip({required this.canExpand});
  final bool canExpand;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    return Container(
      key: const Key('agent-dock-strip'),
      color: XColors.nav,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(children: [
        if (canExpand)
          IconButton(
            key: const Key('code-expand'),
            tooltip: l.codeShowDock,
            onPressed: () => m.setDock(collapsed: false),
            icon: const Icon(Icons.keyboard_double_arrow_left_rounded, size: 20),
          ),
        const SizedBox(height: 8),
        for (final r in m.runs)
          ListenableBuilder(
            listenable: r,
            builder: (context, _) => Tooltip(
              message: '${r.spec.agent} · ${runStateText(l, r)}',
              child: InkWell(
                key: Key('code-strip-${r.spec.agent}'),
                borderRadius: BorderRadius.circular(18),
                onTap: canExpand ? () => m.selectRun(r) : null,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Stack(clipBehavior: Clip.none, children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: XColors.accentSoft,
                      child: Text(
                        r.spec.agent.characters.first.toUpperCase(),
                        style: XText.label.copyWith(color: XColors.accent, fontSize: 12),
                      ),
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: _dot(r),
                          shape: BoxShape.circle,
                          border: Border.all(color: XColors.nav, width: 1.5),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        IconButton(
          key: const Key('code-start-strip'),
          tooltip: l.codeStartAgent,
          onPressed: () => unawaited(showStartAgentDialog(context)),
          icon: const Icon(Icons.add_rounded, size: 20),
        ),
      ]),
    );
  }
}
