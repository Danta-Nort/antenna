// SPDX-License-Identifier: AGPL-3.0-only
// Agents → AI apps: every app the window knows (docs/CONNECT-APPS.md), found ones first, each with its status (is it
// actually connected?) and its best action: Connect where the app has a one-click path, Start in Code mode for the
// terminal agents the window can run, a step-by-step guide for the rest. The role preset for new agents sits below.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_status.dart';
import '../../state/ai_apps.dart';
import '../../state/ai_apps_model.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../code/start_agent_dialog.dart';
import '../widgets/ai_logo.dart';
import '../widgets/experimental_tag.dart';
import '../widgets/section_page.dart';
import '../widgets/x_buttons.dart';
import 'connect_app_dialog.dart';
import 'connect_widgets.dart';
import 'tasks_from.dart';

/// How people know the app, in one line under its name.
String appSubtitle(AppLocalizations l, AiApp a) => switch (a) {
      AiApp.chatgpt => l.appSubChatgpt,
      AiApp.codex => l.appSubCodex,
      AiApp.claudeDesktop => l.appSubClaudeDesktop,
      AiApp.claudeCode => l.appSubClaudeCode,
      AiApp.geminiCli => l.appSubGemini,
      AiApp.cursor => l.appSubCursor,
      AiApp.vscode => l.appSubVscode,
      AiApp.windsurf => l.appSubWindsurf,
      AiApp.zed => l.appSubZed,
      AiApp.lmStudio => l.appSubLmStudio,
      AiApp.grok => l.appSubGrok,
    };

/// "2 min ago" in the window's language.
String agoOf(AppLocalizations l, DateTime t, DateTime now) => agoText(t, now,
    justNow: l.agoJustNow, minutes: l.agoMinutes, hours: l.agoHours, days: l.agoDays);

/// The status as a chip: a dot (and a check when connected) and one word.
class AgentStatusChip extends StatelessWidget {
  const AgentStatusChip(this.status, {super.key});
  final AgentStatus? status;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final s = status?.state;
    final (Color c, String text) = switch (s) {
      // Several MCP processes of one app (D-97): say how many; one is just "Connected".
      AgentLinkState.connected => (
          XColors.ok,
          status!.sessions > 1 ? l.statusConnectedSessions(status!.sessions) : l.statusConnected,
        ),
      AgentLinkState.waiting => (XColors.warn, l.statusWaiting),
      AgentLinkState.disconnected => (XColors.textMute, l.statusDisconnected),
      AgentLinkState.seen => (XColors.accent, l.statusSeen),
      AgentLinkState.revoked => (XColors.danger, l.statusRevoked),
      null => (XColors.textMute, l.statusNotConnected),
    };
    return Container(
      key: Key('status-${s?.name ?? 'none'}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(c.withValues(alpha: XColors.isDark ? 0.16 : 0.10), XColors.bg1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (s == AgentLinkState.connected)
          Icon(Icons.check_circle_rounded, size: 13, color: c)
        else
          Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(text, style: XText.label.copyWith(color: s == null ? XColors.textMute : c, fontSize: 11)),
      ]),
    );
  }
}

/// One line that says what the status means: which process, when it was last seen, or what to do next. [app]: the
/// AI app the agent was connected for (`null`: an agent of the owner's own, e.g. a script).
String? statusDetail(AppLocalizations l, AgentStatus? st, DateTime now, {required String? app}) {
  if (st == null) return null;
  final seen = st.lastSeen == null ? null : agoOf(l, st.lastSeen!, now);
  return switch (st.state) {
    AgentLinkState.connected => [
        if (st.process != null) l.statusProcess(st.process!, '${st.pid}'),
        if (seen != null) l.statusLastSeen(seen),
      ].join(' · '),
    AgentLinkState.waiting => app == null ? l.statusWaitingAgent : l.statusWaitingHint(app),
    AgentLinkState.disconnected => [
        app == null ? l.statusEndedAgent : l.statusEndedHint(app),
        if (seen != null) l.statusLastSeen(seen),
      ].join(' · '),
    AgentLinkState.seen => seen == null ? null : l.statusLastSeen(seen),
    AgentLinkState.revoked => l.statusRevokedHint(app ?? ''),
  };
}

/// Agents → AI apps.
class AiAppsCard extends StatefulWidget {
  const AiAppsCard({super.key});

  @override
  State<AiAppsCard> createState() => _AiAppsCardState();
}

class _AiAppsCardState extends State<AiAppsCard> {
  AiAppsMixin? _model;
  AppLifecycleListener? _focus;

  @override
  void initState() {
    super.initState();
    final m = AppScope.read(context);
    _model = m;
    m.scanAiApps(notify: false);
    m.watchAgents();
    // Back to the window (after installing an app in Terminal, say): look again, so the list does not keep saying
    // "Not found" while it is on screen.
    _focus = AppLifecycleListener(onResume: m.scanAiApps);
  }

  @override
  void dispose() {
    _focus?.dispose();
    _model?.unwatchAgents();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final rows = m.aiAppRows;
    final here = rows.where((r) => r.found || r.connected).toList();
    final elsewhere = rows.where((r) => !r.found && !r.connected).toList();
    return SectionCard(
      key: const Key('ai-apps'),
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.appsTitle, style: XText.title),
        const SizedBox(height: 4),
        Text(l.appsAbout, style: XText.bodyDim),
        const SizedBox(height: 8),
        if (here.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(l.appsNoneFound, style: XText.bodyDim),
          ),
        for (final r in here) AiAppRowView(r),
        if (elsewhere.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(l.appsNotFoundHeader.toUpperCase(), style: XText.overline),
          const SizedBox(height: 4),
          for (final r in elsewhere) AiAppRowView(r),
        ],
      ]),
    );
  }
}

enum _Menu { guide, disconnect, tasks }

class AiAppRowView extends StatelessWidget {
  const AiAppRowView(this.row, {super.key});
  final AiAppRow row;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final app = row.app;
    final st = row.status;
    final shared = app.sharesWith == null ? null : l.appsShared(aiAppDef(app.sharesWith!).name);
    final detail = [
      row.legacyEntry && row.agent == null
          ? l.statusLegacyHint(app.name)
          : statusDetail(l, st, m.now(), app: app.name) ??
              (row.foundAt != null ? l.appsFoundAt(row.foundAt!) : l.appsNotFound),
      ?shared,
    ].join(' · ');
    final terminal = app.terminal != null && m.codeAvailable;
    final oneClick = app.route != ConnectRoute.guide && app.config != null;
    final Widget? primary;
    if (terminal && app.config == null) {
      primary = FilledButton.icon(
        key: Key('app-start-${app.id.name}'),
        style: XButtons.primary(),
        onPressed: () => showStartAgentDialog(context, cli: app.terminal, agent: row.agent?.name),
        icon: const Icon(Icons.terminal_rounded, size: 16),
        label: Text(l.appsStartCode),
      );
    } else if (!row.connected || row.legacyEntry || st?.state == AgentLinkState.revoked) {
      primary = OutlinedButton(
        key: Key('app-connect-${app.id.name}'),
        style: XButtons.secondary(),
        onPressed: () => oneClick ? showConnectAppDialog(context, app) : showAppGuide(context, app),
        child: Text(row.connected || row.legacyEntry
            ? l.appsReconnect
            : oneClick
                ? l.appsConnect
                : l.appsSetUp),
      );
    } else {
      primary = null;
    }
    final menu = <_Menu>[
      _Menu.guide,
      if (row.agent != null) _Menu.tasks,
      if (row.connected) _Menu.disconnect,
    ];
    return Padding(
      key: Key('app-${app.id.name}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Opacity(
          opacity: row.found || row.connected ? 1 : 0.7,
          child: AiLogo(brand: brandOfApp(app.id), label: app.name, size: 38),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(app.name, style: XText.title.copyWith(fontSize: 14)),
              if (row.found) Text(l.appsDetected, key: Key('detected-${app.id.name}'), style: XText.meta),
              if (st != null || row.legacyEntry) AgentStatusChip(st, key: Key('app-status-${app.id.name}')),
            ]),
            const SizedBox(height: 2),
            Text(appSubtitle(l, app.id), style: XText.meta.copyWith(color: XColors.textDim)),
            Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: XText.meta),
            // The agent's name in Antenna: what contacts address (`--to-agent`, the To line), so the owner can tell
            // them; selectable to copy
            if (row.agent != null)
              SelectableText(l.appsAddressedAs(row.agent!.name),
                  key: Key('app-address-${app.id.name}'), style: XText.meta.copyWith(color: XColors.textDim)),
          ]),
        ),
        const SizedBox(width: 8),
        ?primary,
        if (terminal && app.config != null) ...[
          const SizedBox(width: 8),
          IconButton(
            key: Key('app-start-${app.id.name}'),
            tooltip: l.appsStartCode,
            onPressed: () => showStartAgentDialog(context, cli: app.terminal, agent: row.agent?.name),
            icon: const Icon(Icons.terminal_rounded, size: 18),
          ),
        ],
        if (menu.isNotEmpty)
          PopupMenuButton<_Menu>(
            key: Key('app-menu-${app.id.name}'),
            tooltip: l.appsMore,
            icon: const Icon(Icons.more_horiz_rounded, size: 20),
            onSelected: (v) => switch (v) {
              _Menu.guide => showAppGuide(context, app),
              _Menu.disconnect => confirmDisconnectApp(context, row),
              _Menu.tasks => showTasksFromDialog(context, row.agent!.name),
            },
            itemBuilder: (_) => [
              for (final v in menu)
                PopupMenuItem(
                  key: Key('app-menu-${v.name}-${app.id.name}'),
                  value: v,
                  child: switch (v) {
                    _Menu.guide => Text(l.appsGuide),
                    _Menu.disconnect => Text(l.appsDisconnect),
                    _Menu.tasks => Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(l.appsTasksFrom),
                        const SizedBox(width: 8),
                        ExperimentalTag(key: Key('experimental-app-menu-${app.id.name}')),
                      ]),
                  },
                ),
            ],
          ),
      ]),
    );
  }
}
