// SPDX-License-Identifier: AGPL-3.0-only
// Main screen ("light minimalism" reference v2): a narrow section navigation on the left (Chats, Agents, Files,
// Settings); Chats holds the list of links with avatars and the conversation; link details open in a card on the
// right from a button. The product's core (trust level, E2E · PQ, "History verified") is shown as small tags.
// Per the SPEC: no calls, channels or groups ("Spaces" is v2).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../host/daemon_host.dart';
import '../../host/links.dart';
import '../../l10n/l10n.dart';
import '../../state/app_model.dart';
import '../../state/appearance.dart';
import '../../theme/antenna_mark.dart';
import '../../theme/x_theme.dart';
import '../../version.dart';
import '../agents/agents_page.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import '../chat/chat_view.dart';
import '../chat/local_chat_view.dart';
import '../cli/cli_dialog.dart';
import '../code/agent_dock.dart';
import '../code/code_offer.dart';
import '../contact/contact_panel.dart';
import '../devices/devices_page.dart';
import '../files/files_page.dart';
import '../pairing/pairing_dialogs.dart';
import '../settings/check_panel.dart';
import '../settings/settings_page.dart';
import '../teams/teams_page.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import 'contact_list.dart';
import 'self_notice.dart';

enum HomeSection { chats, teams, agents, devices, files, settings }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.center, this.right, this.ribbon, this.initialSection = HomeSection.chats,
      this.initialCard = false});

  /// Only for mockups of future states (the "design" goldens): replace the conversation/card and mark the frame.
  final Widget? center;
  final Widget? right;
  final Widget? ribbon;
  final HomeSection initialSection;
  final bool initialCard;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late HomeSection _section = widget.initialSection;
  late bool _showCard = widget.initialCard;

  /// Watched until the one-time level-5 notice is settled (it needs the contacts).
  AppModel? _noticeModel;

  /// The Code mode dock's "Open board" asks for the Teams section.
  StreamSubscription<void>? _teamsRequests;

  @override
  void initState() {
    super.initState();
    // An invite link reached the app (antenna://, a launch argument, a second window) → "Join"; while the keys are
    // locked, it waits here.
    IncomingLinks.instance.addListener(_openLinks);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openLinks();
      // Code mode is offered once to an owner who has agents: the list is needed to know that.
      if (mounted && (AppearanceScope.read(context)?.canOfferCode ?? false)) AppScope.read(context).refreshAgents();
      if (mounted) {
        _noticeModel = AppScope.read(context)..addListener(_selfNotice);
        _selfNotice();
        _teamsRequests = AppScope.read(context).showTeamsRequests.listen((_) {
          if (mounted) setState(() => _section = HomeSection.teams);
        });
      }
    });
  }

  @override
  void dispose() {
    IncomingLinks.instance.removeListener(_openLinks);
    _noticeModel?.removeListener(_selfNotice);
    unawaited(_teamsRequests?.cancel());
    super.dispose();
  }

  /// The one-time notice about contacts already at level 5, once the contacts are known.
  void _selfNotice() {
    final m = _noticeModel;
    if (!mounted || m == null) return;
    if (maybeShowSelfNotice(context, m, AppearanceScope.read(context))) {
      m.removeListener(_selfNotice);
      _noticeModel = null;
    }
  }

  void _openLinks() {
    if (!mounted) return;
    final link = IncomingLinks.instance.take();
    if (link == null) return;
    setState(() => _section = HomeSection.chats);
    unawaited(showJoinDialog(context, link: link));
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final look = AppearanceScope.maybeOf(context);
    // Code mode is not built for Windows yet: a Code interface chosen before stays in Chat's layout there.
    final code = look?.ui == InterfaceMode.code && !m.codeComing;
    final Widget content = switch (_section) {
      HomeSection.chats => LayoutBuilder(builder: (context, c) {
          final narrow = c.maxWidth < 640;
          final cardFits = c.maxWidth >= 980;
          final card = widget.right != null || (cardFits && _showCard && m.selected != null);
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(width: narrow ? c.maxWidth : (code ? codeListWidth : 340), child: const ContactList()),
            if (!narrow) ...[
              VerticalDivider(width: 1, color: XColors.line),
              Expanded(
                child: widget.center ??
                    // A local agent's conversation takes the place of a link's (CONTROL §24).
                    (m.selectedLocalAgent != null
                        ? LocalChatView(m.selectedLocalAgent!, key: ValueKey('local-${m.selectedLocalAgent}'))
                        : ChatView(
                            cardVisible: card,
                            // The info button and the header's name/avatar stay reachable at every width (Code mode's
                            // terminals can leave less room than the inline panel needs next to the conversation):
                            // wide enough toggles the inline panel, otherwise the same card opens as a dialog.
                            onToggleCard: () {
                              if (cardFits) {
                                setState(() => _showCard = !_showCard);
                              } else {
                                unawaited(showContactCardDialog(context));
                              }
                            },
                          )),
              ),
            ],
            if (card) ...[
              VerticalDivider(width: 1, color: XColors.line),
              SizedBox(width: 360, child: widget.right ?? const ContactPanel()),
            ],
          ]);
        }),
      // A daemon without teams (older than v7, or built before them) shows no Teams section.
      HomeSection.teams => m.teamsSupported ? const TeamsPage() : const SizedBox.shrink(),
      HomeSection.agents => AgentsPage(onOpenChat: (agent) {
          setState(() => _section = HomeSection.chats);
          unawaited(m.selectLocalAgent(agent));
        }),
      HomeSection.devices => const DevicesPage(),
      HomeSection.files => const FilesPage(),
      HomeSection.settings => SettingsPage(onOpenAgents: () => setState(() => _section = HomeSection.agents)),
    };
    final offer = look != null && look.canOfferCode && m.agents.isNotEmpty && m.codeAvailable;
    final Widget main = Stack(children: [
      Positioned.fill(child: ColoredBox(color: XColors.bg1, child: content)),
      if (widget.ribbon != null) Positioned(top: 10, right: 16, child: widget.ribbon!),
    ]);
    final Widget area = offer ? Column(children: [CodeOfferBanner(look), Expanded(child: main)]) : main;
    return Scaffold(
      backgroundColor: XColors.bg1,
      body: LayoutBuilder(
        builder: (context, window) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // The labelled navigation of the reference v3; icons only when the window is too narrow for it next to the
          // terminals of Code mode.
          _NavRail(
            section: _section,
            compact: code && window.maxWidth < navCompactBelow,
            onSelect: (s) => setState(() => _section = s),
          ),
          VerticalDivider(width: 1, color: XColors.line),
          Expanded(
            child: !code
                ? area
                // Code mode: the agents' terminals on the right of every section, so they stay in view.
                : LayoutBuilder(builder: (context, c) {
                    final w = dockWidthFor(c.maxWidth, m.dockWidth);
                    final strip = w == null || m.dockCollapsed;
                    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: area),
                      if (strip) ...[
                        VerticalDivider(width: 1, color: XColors.line),
                        SizedBox(width: dockStripWidth, child: AgentDock(folded: w == null)),
                      ] else ...[
                        DockHandle(
                          onDrag: (dx) => m.setDock(width: (w - dx).clamp(dockMinWidth, c.maxWidth - dockMinContent)),
                        ),
                        SizedBox(width: w, child: const AgentDock()),
                      ],
                    ]);
                  }),
          ),
        ]),
      ),
    );
  }
}

/// Below this window width Code mode folds the navigation to icons, so the conversation and the terminals keep their
/// room (the labelled navigation, the chat list and the conversation take 1,018 px, a docked terminal at least 380).
const navCompactBelow = 1400.0;

/// The chat list's width in Code mode (340 in Chat mode): the terminals need the room.
const codeListWidth = 300.0;

/// The labelled navigation's width.
const navWidth = 216.0;

class _NavRail extends StatelessWidget {
  const _NavRail({required this.section, required this.onSelect, this.compact = false});
  final HomeSection section;
  final ValueChanged<HomeSection> onSelect;

  /// Code mode: icons only, so the conversation and the terminals get the width.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final unread = m.contacts.fold<int>(0, (a, c) => a + m.unreadOf(c));
    if (compact) return _CompactRail(section: section, onSelect: onSelect, unread: unread);
    return Container(
      width: navWidth,
      color: XColors.nav,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(children: [
            const AntennaMark(height: 30),
            const SizedBox(width: 12),
            Text('ANTENNA', style: XText.wordmark),
          ]),
        ),
        const SizedBox(height: 28),
        _NavItem(
          key: const Key('nav-chats'),
          icon: Icons.chat_bubble_outline_rounded,
          label: context.l.navChats,
          selected: section == HomeSection.chats,
          count: unread,
          onTap: () => onSelect(HomeSection.chats),
        ),
        if (m.teamsSupported)
          _NavItem(
            key: const Key('nav-teams'),
            icon: Icons.groups_2_outlined,
            label: context.l.navTeams,
            selected: section == HomeSection.teams,
            count: m.teamsWaiting,
            onTap: () => onSelect(HomeSection.teams),
          ),
        _NavItem(
          key: const Key('agents-button'),
          icon: Icons.smart_toy_outlined,
          label: context.l.navAgents,
          selected: section == HomeSection.agents,
          onTap: () => onSelect(HomeSection.agents),
        ),
        _NavItem(
          key: const Key('nav-devices'),
          icon: Icons.devices_outlined,
          label: context.l.navDevices,
          selected: section == HomeSection.devices,
          count: m.devicesPending,
          onTap: () => onSelect(HomeSection.devices),
        ),
        _NavItem(
          key: const Key('nav-files'),
          icon: Icons.description_outlined,
          label: context.l.navFiles,
          selected: section == HomeSection.files,
          count: m.filesAwaiting.length,
          onTap: () => onSelect(HomeSection.files),
        ),
        _NavItem(
          key: const Key('nav-settings'),
          icon: Icons.settings_outlined,
          label: context.l.navSettings,
          selected: section == HomeSection.settings,
          onTap: () => onSelect(HomeSection.settings),
        ),
        const Spacer(),
        const _DaemonCard(),
        const SizedBox(height: 8),
        Tooltip(
          message: context.l.navLockTooltip,
          child: TextButton.icon(
            key: const Key('lock'),
            onPressed: m.lock,
            style: TextButton.styleFrom(
              foregroundColor: XColors.textDim,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            icon: const Icon(Icons.lock_outline, size: 17),
            label: Text(context.l.commonLockKeys),
          ),
        ),
      ]),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({super.key, required this.icon, required this.label, required this.selected, required this.onTap,
      this.count = 0});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? XColors.accent : XColors.textDim;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(XRadius.m),
          child: AnimatedContainer(
            duration: XMotion.fast,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? XColors.accentSoft : null,
              borderRadius: BorderRadius.circular(XRadius.m),
            ),
            child: Row(children: [
              Icon(icon, size: 19, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: XText.body.copyWith(color: selected ? XColors.accent : XColors.text, fontWeight: FontWeight.w500),
                ),
              ),
              if (count > 0) CountBubble(count),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The navigation in Code mode: the mark, the section icons with their counters, the daemon dot, lock.
class _CompactRail extends StatelessWidget {
  const _CompactRail({required this.section, required this.onSelect, required this.unread});
  final HomeSection section;
  final ValueChanged<HomeSection> onSelect;
  final int unread;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    Widget item(Key key, IconData icon, String label, HomeSection s, {int count = 0}) {
      final selected = section == s;
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Tooltip(
          message: label,
          child: InkWell(
            key: key,
            onTap: () => onSelect(s),
            borderRadius: BorderRadius.circular(XRadius.m),
            child: Container(
              width: 44,
              height: 40,
              decoration: BoxDecoration(
                color: selected ? XColors.accentSoft : null,
                borderRadius: BorderRadius.circular(XRadius.m),
              ),
              child: Stack(clipBehavior: Clip.none, children: [
                Center(child: Icon(icon, size: 20, color: selected ? XColors.accent : XColors.textDim)),
                if (count > 0) Positioned(right: -4, top: -2, child: CountBubble(count)),
              ]),
            ),
          ),
        ),
      );
    }

    final st = m.status;
    return Container(
      key: const Key('nav-compact'),
      width: 64,
      color: XColors.nav,
      padding: const EdgeInsets.fromLTRB(8, 24, 8, 16),
      child: Column(children: [
        const AntennaMark(height: 28),
        const SizedBox(height: 24),
        item(const Key('nav-chats'), Icons.chat_bubble_outline_rounded, l.navChats, HomeSection.chats, count: unread),
        if (m.teamsSupported)
          item(const Key('nav-teams'), Icons.groups_2_outlined, l.navTeams, HomeSection.teams, count: m.teamsWaiting),
        item(const Key('agents-button'), Icons.smart_toy_outlined, l.navAgents, HomeSection.agents),
        item(const Key('nav-devices'), Icons.devices_outlined, l.navDevices, HomeSection.devices,
            count: m.devicesPending),
        item(const Key('nav-files'), Icons.description_outlined, l.navFiles, HomeSection.files,
            count: m.filesAwaiting.length),
        item(const Key('nav-settings'), Icons.settings_outlined, l.navSettings, HomeSection.settings),
        const Spacer(),
        if (st != null)
          Tooltip(
            message: st.daemon.replaceFirst(RegExp(r' \(.*\)$'), ''),
            child: InkWell(
              key: const Key('daemon-pill'),
              onTap: () => showDaemonDialog(context),
              borderRadius: BorderRadius.circular(XRadius.m),
              child: SizedBox(
                width: 44,
                height: 36,
                child: Center(
                  child: Container(width: 9, height: 9, decoration: BoxDecoration(color: XColors.ok, shape: BoxShape.circle)),
                ),
              ),
            ),
          ),
        IconButton(
          key: const Key('lock'),
          tooltip: l.navLockTooltip,
          onPressed: m.lock,
          color: XColors.textDim,
          icon: const Icon(Icons.lock_outline, size: 18),
        ),
      ]),
    );
  }
}

/// Bottom of the navigation: daemon version, relay and number of links; tap for daemon details.
class _DaemonCard extends StatelessWidget {
  const _DaemonCard();

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final st = m.status;
    if (st == null) return const SizedBox.shrink();
    final relay = st.relay == 'disabled' ? context.l.navRelayOff : 'relay ${st.relay}';
    return Tooltip(
      message: context.l.navDaemonTooltip,
      child: InkWell(
        key: const Key('daemon-pill'),
        onTap: () => showDaemonDialog(context),
        borderRadius: BorderRadius.circular(XRadius.m),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: XColors.bg1,
            borderRadius: BorderRadius.circular(XRadius.m),
            border: Border.all(color: XColors.line),
          ),
          child: Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: XColors.ok, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // The build commit is in the daemon dialog; only the version here.
                Text(
                  st.daemon.replaceFirst(RegExp(r' \(.*\)$'), ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: XText.meta.copyWith(color: XColors.text, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                // The window's contact list, not `status.links`: the list follows the daemon (re-read after every
                // new link, on `contact` events and every 10 s), while `status` is read once when the window
                // connects, so its count stayed at the old number after a pairing.
                Text('$relay · ${context.l.navContactsCount(m.contacts.length)}', style: XText.meta),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Daemon details, and control of our own daemon (if the window started it).
Future<void> showDaemonDialog(BuildContext context) => showXDialog<void>(context, (ctx) {
      return XDialogShell(
        title: 'Daemon',
        icon: Icons.memory_outlined,
        width: 560,
        actions: [
          if (AppScope.of(ctx).host != null)
            OutlinedButton(
              key: const Key('daemon-stop'),
              onPressed: () async {
                Navigator.pop(ctx);
                await AppScope.read(context).stopDaemon();
              },
              child: Text(ctx.l.commonStopDaemon),
            ),
          OutlinedButton(
            key: const Key('daemon-cli'),
            onPressed: () {
              Navigator.pop(ctx);
              showCliDialog(context);
            },
            child: Text(ctx.l.commonCliCommand),
          ),
          OutlinedButton.icon(
            key: const Key('daemon-check'),
            onPressed: () {
              Navigator.pop(ctx);
              showCheckDialog(context);
            },
            icon: const Icon(Icons.fact_check_outlined, size: 16),
            label: Text(ctx.l.daemonCheck),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l.commonClose)),
        ],
        child: const DaemonFacts(),
      );
    });

/// Daemon facts (the dialog and Settings).
class DaemonFacts extends StatelessWidget {
  const DaemonFacts({super.key, this.note = true});

  /// The line on what stopping does (Settings has it behind the "?").
  final bool note;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final h = m.host;
    final st = m.status;
    final l = context.l;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FactRow(l.daemonFactWindow, appVersionLine),
      FactRow(l.daemonFactVersion, st == null ? '—' : '${st.daemon} · ${l.gateFooterProtocol(st.protocol)} · ${m.hello?.proto ?? ''}'),
      FactRow(l.daemonFactState, st?.state.name ?? '—'),
      FactRow('Relay', st?.relay ?? '—'),
      FactRow(l.daemonFactSocket, m.socketPath),
      FactRow(l.daemonFactStartedBy, switch (h) {
        LaunchAgentHost() => l.daemonStartedByLaunchAgent,
        ChildProcessHost() => l.daemonStartedByChild,
        _ => l.daemonStartedByOther,
      }),
      if (h != null) FactRow('antennad', h.xdPath),
      if (h != null) FactRow(l.daemonFactLog, h.logPath),
      if (m.binaries?.cli != null) FactRow(l.daemonFactCli, m.binaries!.cli!),
      if (note) ...[
        const SizedBox(height: 8),
        Text(
          l.daemonStopNote,
          style: XText.bodyDim.copyWith(fontSize: 12),
        ),
      ],
    ]);
  }
}
