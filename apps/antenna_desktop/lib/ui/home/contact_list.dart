// SPDX-License-Identifier: AGPL-3.0-only
// List of links: people and agents in one list (SPEC §1, §11), a trust level badge, the delivery status of the last
// outgoing message, presence only for levels 3+ (SPEC §4). On top: what waits for the owner, approval requests and
// live invites (Q-7). Each agent of a contact is its own chat (D-UI-32): a row under the contact's row (the person
// chat), with its local name, its unread count and its menu; archived chats wait folded at the end.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/format.dart';
import '../../state/local_models.dart';
import '../../state/threads.dart';
import '../../state/trust.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../approvals/approvals_view.dart';
import '../pairing/pairing_dialogs.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/agent_logo.dart';
import '../widgets/badges.dart';
import '../widgets/local_badge.dart';
import 'chat_menu.dart';

enum _Filter { all, unread, queued }

class ContactList extends StatefulWidget {
  const ContactList({super.key});

  @override
  State<ContactList> createState() => _ContactListState();
}

class _ContactListState extends State<ContactList> {
  final _q = TextEditingController();
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final q = _q.text.trim().toLowerCase();
    // A contact's row and the rows of its agent chats: a search finds a contact by its label or one of its chats by
    // the agent's or the local name; "Unread" keeps the chats with unread messages (and their contact's row above).
    final rows = <Widget>[];
    for (final c in m.contacts) {
      final contactHit = q.isEmpty || c.label.toLowerCase().contains(q) || c.linkId.startsWith(q);
      final agents = [
        for (final k in m.agentChatsOf(c.linkId))
          if ((contactHit ||
                  k.agent!.toLowerCase().contains(q) ||
                  (m.chatName(c.linkId, k)?.toLowerCase().contains(q) ?? false)) &&
              // The chat on screen stays while it is read, as in any messenger
              (_filter != _Filter.unread ||
                  m.chatUnread(c.linkId, k) > 0 ||
                  (m.selectedLinkId == c.linkId && m.openThreadOf(c.linkId) == k)) &&
              _filter != _Filter.queued)
            k,
      ];
      final contactPasses = contactHit &&
          switch (_filter) {
            _Filter.all => true,
            _Filter.unread => m.unreadOf(c) > 0,
            _Filter.queued => c.outbox > 0 || c.failed > 0,
          };
      if (!contactPasses && agents.isEmpty) continue;
      rows.add(_ContactTile(c));
      // Pinned chats stay on top in pin order (not draggable: their order is "when it was pinned", D-UI-43); the
      // rest keep the stable order the owner can drag, in one block so dragging never crosses into the pinned ones.
      final pinned = [for (final k in agents) if (m.isChatPinned(c.linkId, k.agent!)) k];
      final rest = [for (final k in agents) if (!m.isChatPinned(c.linkId, k.agent!)) k];
      for (final k in pinned) {
        rows.add(_AgentChatTile(c, k));
      }
      // Dragging a filtered view would silently drop whatever the filter hid from the saved order, so the drag turns
      // on only over the unfiltered list ("All", no search).
      final reorderable = q.isEmpty && _filter == _Filter.all;
      if (rest.isNotEmpty) rows.add(_AgentChatBlock(c, rest, reorderable: reorderable));
    }
    final archived = _filter == _Filter.all ? m.archivedChats() : const <(ContactInfo, ThreadKey)>[];
    if (archived.isNotEmpty) {
      rows.add(_ArchivedHeader(archived.length, open: m.archivedShown, onTap: () {
        setState(() => m.archivedShown = !m.archivedShown);
      }));
      if (m.archivedShown) {
        for (final (c, k) in archived) {
          rows.add(_AgentChatTile(c, k, archived: true));
        }
      }
    }
    final anyAgents = m.contacts.any((c) => c.agents.isNotEmpty || m.agentChatsOf(c.linkId).isNotEmpty);
    // Local agents have no unread counts or queues: they show under "All" and by name.
    final local = _filter != _Filter.all
        ? const <LocalAgentInfo>[]
        : [for (final a in m.localAgents) if (q.isEmpty || a.name.toLowerCase().contains(q)) a];
    return ColoredBox(
      color: XColors.bg1,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 12, 4),
          child: Row(children: [
            Expanded(child: Text(context.l.navChats, style: XText.h2)),
            if (anyAgents)
              IconButton(
                key: const Key('new-chat'),
                tooltip: context.l.chatsNewChatTooltip,
                onPressed: () => showNewChatDialog(context),
                icon: const Icon(Icons.forum_outlined, size: 20),
              ),
            IconButton(
              key: const Key('new-link'),
              tooltip: context.l.listNewContactTooltip,
              onPressed: () => showPairingMenu(context),
              icon: const Icon(Icons.add_comment_outlined, size: 20),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _q,
            onChanged: (_) => setState(() {}),
            style: XText.body,
            decoration: InputDecoration(
              hintText: context.l.listSearchHint,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(XRadius.m), borderSide: BorderSide.none),
              enabledBorder:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(XRadius.m), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          // Scrolls sideways when the list is narrow (Code mode, long Russian labels).
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final f in _Filter.values) _Tab(f, _filter == f, () => setState(() => _filter = f)),
              ]),
            ),
          ),
        ),
        if (m.approvals.isNotEmpty || m.questions.isNotEmpty)
          _ApprovalsBanner(m.approvals.length + m.questions.length, questionsOnly: m.approvals.isEmpty),
        for (final i in m.pendingInvites) _InviteTile(i),
        Expanded(
          child: local.isNotEmpty
              // Local agents first, in their own section above the contacts (docs/LOCAL-ASSISTANT.md §7.1).
              ? ListView(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8), children: [
                  _SectionLabel(context.l.listOnThisComputer, key: const Key('list-on-this-computer')),
                  for (final a in local) LocalAgentTile(a),
                  const SizedBox(height: 8),
                  _SectionLabel(context.l.listContactsSection),
                  if (m.contacts.isEmpty) const _Empty() else ...rows,
                ])
              : m.contacts.isEmpty
                  ? const _Empty()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      children: rows,
                    ),
        ),
      ]),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab(this.f, this.active, this.onTap);
  final _Filter f;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = switch (f) {
      _Filter.all => context.l.listFilterAll,
      _Filter.unread => context.l.listFilterUnread,
      _Filter.queued => context.l.listFilterQueued,
    };
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: XMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: active ? XColors.accentSoft : null,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: active ? Colors.transparent : XColors.line),
          ),
          child: Text(label, style: XText.label.copyWith(color: active ? XColors.accent : XColors.textDim)),
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile(this.c);
  final ContactInfo c;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    const k = ThreadKey.person;
    final selected = m.selectedLinkId == c.linkId && m.openThreadOf(c.linkId).isPerson;
    // The person chat's own latest message; its count, and the contact's whole count when it has no agent chats
    final last = m.lastEntryOf(c.linkId, k);
    final unread = m.agentChatsOf(c.linkId).isEmpty ? m.unreadOf(c) : m.chatUnread(c.linkId, k);
    final presence = m.presenceOf(c);
    final now = m.now();
    final (preview, previewColor) = !selected && m.hasDraft(c.linkId, k)
        ? (context.l.listPreviewDraft(m.draftLine(c.linkId, k)), XColors.warn)
        : _preview(context.l, m, c, last);
    final muted = m.chatNotify(c.linkId, k) == ChatNotify.off;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        key: Key('contact-${c.label}'),
        borderRadius: BorderRadius.circular(XRadius.l),
        onTap: () => m.select(c.linkId, chat: k),
        onSecondaryTapUp: (d) => showChatMenuAt(context, c, k, d.globalPosition),
        child: AnimatedContainer(
          duration: XMotion.fast,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          decoration: BoxDecoration(
            color: selected ? XColors.accentSoft : null,
            borderRadius: BorderRadius.circular(XRadius.l),
            border: XColors.isDark && selected ? Border.all(color: XColors.accentLine) : null,
          ),
          child: Row(children: [
            XAvatar(c.label,
                size: 40, presence: presence, agent: c.peerKind == 'agent', picture: m.pictureOfContact(c.linkId)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Row(children: [
                      Flexible(
                        child: Text(c.label, overflow: TextOverflow.ellipsis, style: XText.title.copyWith(fontSize: 14)),
                      ),
                      const SizedBox(width: 8),
                      TrustBadge(c.trust, size: 16),
                      if (c.peerKind == 'mixed' || (c.peerKind == 'agent' && c.activeAgents.isNotEmpty)) ...[
                        const SizedBox(width: 8),
                        PeerKindTag(c),
                      ],
                    ]),
                  ),
                  const SizedBox(width: 8),
                  if (muted) ...[const _MutedMark(), const SizedBox(width: 4)],
                  Text(
                    last != null ? shortStamp(context.l, last.at, now) : shortStamp(context.l, DateTime.fromMillisecondsSinceEpoch(c.createdMs), now),
                    style: XText.meta.copyWith(color: unread > 0 ? XColors.accent : XColors.textMute),
                  ),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  if (last != null && last.outgoing && last.delivery != null) ...[
                    DeliveryMark(last.delivery!, size: 13),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: XText.bodyDim.copyWith(fontSize: 12, color: previewColor),
                    ),
                  ),
                  if (unread > 0) CountBubble(unread),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  (String, Color) _preview(AppLocalizations l, AppModel m, ContactInfo c, ChatEntry? last) {
    if (c.failed > 0) return (l.listPreviewFailed(c.failed), XColors.danger);
    final file = last == null ? null : m.fileByMessage(last.id);
    if (file != null) {
      final text = l.listPreviewFile(file.name);
      return (last!.outgoing ? l.listPreviewYou(text) : text, XColors.textDim);
    }
    if (last != null) {
      final text = last.text.replaceAll('\n', ' ');
      return (last.outgoing ? l.listPreviewYou(text) : text, XColors.textDim);
    }
    if (c.outbox > 0) return (l.listPreviewQueued(c.outbox), XColors.warn);
    final mode = netModeLabel(l, c.netMode).toLowerCase();
    return ('${c.role == 'inviter' ? l.commonYouInvited : l.commonYouJoined} · $mode', XColors.textMute);
  }
}

/// The contact's unpinned agent chats, in their stable order: a plain column, or (over the unfiltered list,
/// [reorderable]) a press-and-hold drag that saves the new order (`AppModel.reorderChats`, D-UI-43). A normal tap
/// still opens the chat; only a hold starts the drag ([ReorderableDelayedDragStartListener]), so the two gestures
/// never fight each other.
class _AgentChatBlock extends StatelessWidget {
  const _AgentChatBlock(this.c, this.keys, {required this.reorderable});
  final ContactInfo c;
  final List<ThreadKey> keys;
  final bool reorderable;

  @override
  Widget build(BuildContext context) {
    if (!reorderable) {
      return Column(children: [for (final k in keys) _AgentChatTile(c, k)]);
    }
    final m = AppScope.of(context);
    return ReorderableListView(
      key: Key('agent-chats-${c.label}'),
      buildDefaultDragHandles: false,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      onReorderItem: (oldIndex, newIndex) {
        // `onReorderItem` (unlike the obsolete `onReorder`) already adjusts `newIndex` for the removed item.
        final names = [for (final k in keys) k.agent!];
        final name = names.removeAt(oldIndex);
        names.insert(newIndex, name);
        m.reorderChats(c.linkId, names);
      },
      children: [
        for (final (i, k) in keys.indexed)
          ReorderableDelayedDragStartListener(
            key: Key('agent-chat-drag-${chatKeyId(c, k)}'),
            index: i,
            child: _AgentChatTile(c, k),
          ),
      ],
    );
  }
}

/// One chat with an agent of the contact: under the contact's row, indented, with the agent's picture, the local name
/// (or the agent's name), the latest message, its unread count and its menu. In the Archived section ([archived]) it
/// stands alone and says whose agent it is.
class _AgentChatTile extends StatelessWidget {
  const _AgentChatTile(this.c, this.k, {this.archived = false});
  final ContactInfo c;
  final ThreadKey k;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final selected = m.selectedLinkId == c.linkId && m.openThreadOf(c.linkId) == k;
    final last = m.lastEntryOf(c.linkId, k);
    // The badge counts what is for the person; agent-to-agent traffic is a quiet dot at most (D-UI-44).
    final unread = m.chatUnreadForPerson(c.linkId, k);
    final unreadBetweenAgents = m.chatUnreadBetweenAgents(c.linkId, k) > 0;
    final name = m.chatName(c.linkId, k);
    final title = chatTitle(l, m, c, k, withContact: archived);
    final muted = m.chatNotify(c.linkId, k) == ChatNotify.off;
    final info = m.chatInfoOf(c.linkId, k);
    final at = last?.at ?? (info?.lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(info!.lastMs!));
    final file = last == null ? null : m.fileByMessage(last.id);
    final preview = last == null
        ? ''
        : (file != null ? l.listPreviewFile(file.name) : last.text.replaceAll('\n', ' '));
    final mineWrote = last != null && last.outgoing && last.viaAgent == null;
    final draft = !selected && m.hasDraft(c.linkId, k);
    return Padding(
      padding: EdgeInsets.only(left: archived ? 0 : 24, top: 1, bottom: 1),
      child: Tooltip(
        message: l.chatAgentTitle(c.label, k.agent!),
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          key: Key('chat-${chatKeyId(c, k)}'),
          borderRadius: BorderRadius.circular(XRadius.l),
          onTap: () => m.select(c.linkId, chat: k),
          onSecondaryTapUp: (d) => showChatMenuAt(context, c, k, d.globalPosition),
          child: AnimatedContainer(
            duration: XMotion.fast,
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            decoration: BoxDecoration(
              color: selected ? XColors.accentSoft : null,
              borderRadius: BorderRadius.circular(XRadius.l),
              border: XColors.isDark && selected ? Border.all(color: XColors.accentLine) : null,
            ),
            child: Row(children: [
              AgentAvatar(AgentRef(k.agent!, contact: c.label, linkId: c.linkId), size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    // The name first; a renamed chat still says which agent it is, in what room is left
                    Expanded(
                      child: Row(children: [
                        Flexible(
                          flex: 4,
                          child:
                              Text(title, overflow: TextOverflow.ellipsis, style: XText.title.copyWith(fontSize: 14)),
                        ),
                        if (name != null && !archived) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            flex: 1,
                            child: Text(k.agent!,
                                overflow: TextOverflow.ellipsis, style: XText.meta.copyWith(color: XColors.textMute)),
                          ),
                        ],
                      ]),
                    ),
                    const SizedBox(width: 8),
                    if (muted) ...[const _MutedMark(), const SizedBox(width: 4)],
                    if (at != null)
                      Text(shortStamp(l, at, m.now()),
                          style: XText.meta.copyWith(color: unread > 0 ? XColors.accent : XColors.textMute)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    if (last != null && last.outgoing && last.delivery != null) ...[
                      DeliveryMark(last.delivery!, size: 13),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        draft
                            ? l.listPreviewDraft(m.draftLine(c.linkId, k))
                            : (mineWrote ? l.listPreviewYou(preview) : preview),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: XText.bodyDim.copyWith(fontSize: 12, color: draft ? XColors.warn : XColors.textDim),
                      ),
                    ),
                    if (unreadBetweenAgents) ...[const QuietUnreadDot(), const SizedBox(width: 4)],
                    if (unread > 0) CountBubble(unread),
                  ]),
                ]),
              ),
              ChatMenuButton(c, k, size: 16),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The folded section of archived chats: "Archived (N)".
class _ArchivedHeader extends StatelessWidget {
  const _ArchivedHeader(this.count, {required this.open, required this.onTap});
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Tooltip(
          message: open ? context.l.chatsArchivedHide : context.l.chatsArchivedShow,
          child: InkWell(
            key: const Key('chats-archived'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(XRadius.m),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Icon(Icons.archive_outlined, size: 16, color: XColors.textMute),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(context.l.chatsArchivedSection(count).toUpperCase(), style: XText.overline),
                ),
                Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: XColors.textMute),
              ]),
            ),
          ),
        ),
      );
}

/// A chat whose notifications are off.
class _MutedMark extends StatelessWidget {
  const _MutedMark();

  @override
  Widget build(BuildContext context) => Tooltip(
        message: context.l.chatNotifyOffTip,
        child: Icon(Icons.notifications_off_outlined, size: 13, color: XColors.textMute),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(text.toUpperCase(), style: XText.overline),
      );
}

/// A local agent's conversation in the list: its picture, name, the short Local badge, and its last message or state.
class LocalAgentTile extends StatelessWidget {
  const LocalAgentTile(this.a, {super.key});
  final LocalAgentInfo a;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final selected = m.selectedLocalAgent == a.name;
    final last = m.localChats[a.name]?.items.lastOrNull;
    final model = m.localModel(a.model)?.name ?? a.model;
    final preview = last == null
        ? '$model · ${localAgentStateLabel(l, a.state)}'
        : (last.byOwner ? l.listPreviewYou(plainModelText(last.text)) : plainModelText(last.text)).replaceAll('\n', ' ');
    final stamp = last == null && a.lastTurnMs == null
        ? null
        : shortStamp(l, DateTime.fromMillisecondsSinceEpoch(last?.tsMs ?? a.lastTurnMs!), m.now());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        key: Key('local-tile-${a.name}'),
        borderRadius: BorderRadius.circular(XRadius.l),
        onTap: () => m.selectLocalAgent(a.name),
        child: AnimatedContainer(
          duration: XMotion.fast,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          decoration: BoxDecoration(
            color: selected ? XColors.accentSoft : null,
            borderRadius: BorderRadius.circular(XRadius.l),
            border: XColors.isDark && selected ? Border.all(color: XColors.accentLine) : null,
          ),
          child: Row(children: [
            XAvatar(a.name, size: 40, agent: true, picture: m.pictureOfMine(agent: a.name)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(a.name, overflow: TextOverflow.ellipsis, style: XText.title.copyWith(fontSize: 14)),
                  ),
                  const SizedBox(width: 8),
                  LocalBadge(a, short: true),
                  const Spacer(),
                  if (stamp != null) Text(stamp, style: XText.meta.copyWith(color: XColors.textMute)),
                ]),
                const SizedBox(height: 4),
                Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: XText.bodyDim.copyWith(fontSize: 12, color: XColors.textDim)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.hub_outlined, size: 30, color: XColors.textMute),
          const SizedBox(height: 12),
          Text(context.l.listEmptyTitle, style: XText.title),
          const SizedBox(height: 8),
          Text(
            context.l.listEmptyBody,
            textAlign: TextAlign.center,
            style: XText.bodyDim.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => showInviteDialog(context),
            icon: const Icon(Icons.qr_code_2, size: 16),
            label: Text(context.l.commonInvite),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => showJoinDialog(context), child: Text(context.l.listHaveLink)),
        ]),
      );
}

class _ApprovalsBanner extends StatelessWidget {
  const _ApprovalsBanner(this.count, {this.questionsOnly = false});
  final int count;

  /// Only the agents' questions wait (D-118), no approval request.
  final bool questionsOnly;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: InkWell(
          key: const Key('approvals-banner'),
          onTap: () => showApprovalsDialog(context),
          borderRadius: BorderRadius.circular(XRadius.m),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: xGlow(radius: XRadius.l, color: XColors.warn, strength: 0.8),
            child: Row(children: [
              Icon(questionsOnly ? Icons.contact_support_outlined : Icons.gpp_maybe_outlined,
                  size: 18, color: XColors.warn),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(questionsOnly ? context.l.questionsTitle : context.l.approvalsTitle,
                      style: XText.title)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: XColors.warn, borderRadius: BorderRadius.circular(10)),
                child: Text('$count', style: XText.monoStrong.copyWith(color: XColors.onStatus, fontSize: 11)),
              ),
            ]),
          ),
        ),
      );
}

class _InviteTile extends StatelessWidget {
  const _InviteTile(this.i);
  final InviteInfo i;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final (phase, color) = invitePhaseLabel(context.l, i.phase);
    final left = DateTime.fromMillisecondsSinceEpoch(i.expiresMs).difference(m.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: InkWell(
        onTap: () => showInviteMonitor(context, i.id),
        borderRadius: BorderRadius.circular(XRadius.m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(XRadius.l),
            border: Border.all(color: i.needsConfirm ? XColors.warn.withValues(alpha: 0.7) : XColors.line),
            color: XColors.bg2,
          ),
          child: Row(children: [
            Icon(Icons.qr_code_2, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i.label == null ? context.l.inviteTitle : context.l.inviteTitleNamed(i.label!), style: XText.label.copyWith(color: XColors.text)),
                const SizedBox(height: 2),
                Text(phase, style: XText.monoSmall.copyWith(color: color)),
              ]),
            ),
            Text(countdown(left), style: XText.monoSmall.copyWith(color: XColors.warn)),
          ]),
        ),
      ),
    );
  }
}
