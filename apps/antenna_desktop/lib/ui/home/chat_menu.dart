// SPDX-License-Identifier: AGPL-3.0-only
// A chat's options (D-UI-32): the same menu from the ⋮ of a list row, a right click on it, and the ⋮ of the
// conversation header. Rename (a local name for a chat with an agent; the contact's own label for the person chat),
// notifications (all messages, only when it asks for me, off) and archive. All of it is kept by the daemon on this
// computer and never sent (CONTROL §26); a daemon without chats keeps none of it, and the items say so. Also the
// rename dialog and the "New chat with an agent" dialog.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/messages.dart';
import '../../state/threads.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../contact/contact_panel.dart' show showContactRename;
import '../files/media_files.dart' show showMediaAndFiles;
import '../pictures/chat_picture_picker.dart' show showChatPicturePicker;
import '../widgets/agent_avatar.dart';
import '../widgets/agent_logo.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';

/// What the chat menu does.
enum ChatAction {
  media,
  rename,
  notifyAll,
  notifyAsks,
  notifyOff,
  notifyAgentsOn,
  notifyAgentsOff,
  setPicture,
  pin,
  unpin,
  archive,
  unarchive
}

/// A chat's name as the owner sees it: the local name, or the contact's label for the person chat, or "contact ·
/// agent" ([withContact]) or the agent's name alone (a row under the contact's row).
String chatTitle(AppLocalizations l, AppModel m, ContactInfo c, ThreadKey k, {bool withContact = true}) {
  final name = m.chatName(c.linkId, k);
  if (name != null) return name;
  if (k.isPerson) return c.label;
  return withContact ? l.chatAgentTitle(c.label, k.agent!) : k.agent!;
}

/// The menu's items for the chat [k] of [c].
List<PopupMenuEntry<ChatAction>> chatMenuItems(BuildContext context, ContactInfo c, ThreadKey k) {
  final l = context.l;
  final m = AppScope.read(context);
  final can = m.chatsSupported;
  final notify = m.chatNotify(c.linkId, k);
  final archived = m.chatArchived(c.linkId, k);
  PopupMenuItem<ChatAction> notifyItem(ChatAction a, String value, String label, String hint) => PopupMenuItem(
        key: Key('chat-menu-notify-$value'),
        value: a,
        enabled: can,
        child: Tooltip(
          message: can ? '' : l.chatSettingsNeedNewer,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              SizedBox(
                width: 24,
                child: notify == value ? Icon(Icons.check_rounded, size: 16, color: XColors.accent) : null,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(label,
                      style: XText.body.copyWith(fontWeight: notify == value ? FontWeight.w600 : FontWeight.w400)),
                  Text(hint, style: XText.meta),
                ]),
              ),
            ]),
          ),
        ),
      );
  return [
    PopupMenuItem(
      key: const Key('chat-menu-media'),
      value: ChatAction.media,
      child: Row(children: [
        Icon(Icons.perm_media_outlined, size: 16, color: XColors.textDim),
        const SizedBox(width: 16),
        Text(l.chatMenuMedia, style: XText.body),
      ]),
    ),
    PopupMenuItem(
      key: const Key('chat-menu-rename'),
      value: ChatAction.rename,
      // The person chat is the contact: its name is the contact's own label, which needs no newer daemon
      enabled: can || k.isPerson,
      child: Row(children: [
        Icon(Icons.edit_outlined, size: 16, color: XColors.textDim),
        const SizedBox(width: 16),
        Text(k.isPerson ? l.chatMenuRenameContact : l.chatMenuRename, style: XText.body),
      ]),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(
      enabled: false,
      height: 32,
      child: Text(l.chatMenuNotifications.toUpperCase(), style: XText.overline),
    ),
    notifyItem(ChatAction.notifyAll, ChatNotify.all, l.chatNotifyAll, l.chatNotifyAllHint),
    notifyItem(ChatAction.notifyAsks, ChatNotify.asks, l.chatNotifyAsks, l.chatNotifyAsksHint),
    notifyItem(ChatAction.notifyOff, ChatNotify.off, l.chatNotifyOff, l.chatNotifyOffHint),
    if (!k.isPerson)
      PopupMenuItem(
        // Local to this computer (D-UI-44), off by default: needs no newer daemon.
        key: const Key('chat-menu-notify-agents'),
        value: m.notifyAgentsOn(c.linkId, k.agent!) ? ChatAction.notifyAgentsOff : ChatAction.notifyAgentsOn,
        child: Row(children: [
          SizedBox(
            width: 24,
            child: m.notifyAgentsOn(c.linkId, k.agent!)
                ? Icon(Icons.check_rounded, size: 16, color: XColors.accent)
                : null,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(l.chatNotifyAgentsToggle, style: XText.body)),
        ]),
      ),
    if (!k.isPerson) ...[
      const PopupMenuDivider(),
      PopupMenuItem(
        // A phone book entry, local to this computer (D-UI-43): needs no newer daemon.
        key: const Key('chat-menu-set-picture'),
        value: ChatAction.setPicture,
        child: Row(children: [
          Icon(Icons.add_a_photo_outlined, size: 16, color: XColors.textDim),
          const SizedBox(width: 16),
          Text(l.chatMenuSetPicture, style: XText.body),
        ]),
      ),
      PopupMenuItem(
        // Local to this computer, like the order itself (D-UI-43): needs no newer daemon.
        key: Key(m.isChatPinned(c.linkId, k.agent!) ? 'chat-menu-unpin' : 'chat-menu-pin'),
        value: m.isChatPinned(c.linkId, k.agent!) ? ChatAction.unpin : ChatAction.pin,
        child: Row(children: [
          Icon(m.isChatPinned(c.linkId, k.agent!) ? Icons.push_pin : Icons.push_pin_outlined,
              size: 16, color: XColors.textDim),
          const SizedBox(width: 16),
          Text(m.isChatPinned(c.linkId, k.agent!) ? l.chatMenuUnpin : l.chatMenuPin, style: XText.body),
        ]),
      ),
      PopupMenuItem(
        key: Key(archived ? 'chat-menu-unarchive' : 'chat-menu-archive'),
        value: archived ? ChatAction.unarchive : ChatAction.archive,
        enabled: can,
        child: Row(children: [
          Icon(archived ? Icons.unarchive_outlined : Icons.archive_outlined, size: 16, color: XColors.textDim),
          const SizedBox(width: 16),
          Text(archived ? l.chatMenuUnarchive : l.chatMenuArchive, style: XText.body),
        ]),
      ),
    ],
  ];
}

/// Carries out a menu choice; an error is shown in a snack bar.
Future<void> onChatAction(BuildContext context, ContactInfo c, ThreadKey k, ChatAction a) async {
  final m = AppScope.read(context);
  final l = context.l;
  final messenger = ScaffoldMessenger.maybeOf(context);
  Object? err;
  switch (a) {
    case ChatAction.media:
      return showMediaAndFiles(context, c, k: k);
    case ChatAction.rename:
      if (k.isPerson) return showContactRename(context, c);
      return showChatRename(context, c, k);
    case ChatAction.notifyAll:
      err = await m.setChatNotify(c.linkId, k, ChatNotify.all);
    case ChatAction.notifyAsks:
      err = await m.setChatNotify(c.linkId, k, ChatNotify.asks);
    case ChatAction.notifyOff:
      err = await m.setChatNotify(c.linkId, k, ChatNotify.off);
    case ChatAction.notifyAgentsOn:
      m.setNotifyAgentsOn(c.linkId, k.agent!, true);
    case ChatAction.notifyAgentsOff:
      m.setNotifyAgentsOn(c.linkId, k.agent!, false);
    case ChatAction.setPicture:
      return showChatPicturePicker(context, linkId: c.linkId, agent: k.agent!);
    case ChatAction.pin:
      m.setChatPinned(c.linkId, k.agent!, true);
    case ChatAction.unpin:
      m.setChatPinned(c.linkId, k.agent!, false);
    case ChatAction.archive:
      err = await m.archiveChat(c.linkId, k, archived: true);
      if (err == null) messenger?.showSnackBar(SnackBar(content: Text(l.chatArchivedNote)));
    case ChatAction.unarchive:
      err = await m.archiveChat(c.linkId, k, archived: false);
  }
  if (err != null) messenger?.showSnackBar(SnackBar(content: Text(describeError(l, err))));
}

/// Wide enough for the notification hints in one line, in Russian too.
const _menuWidth = BoxConstraints(minWidth: 320, maxWidth: 360);

/// The menu as a panel of reference v3: the window's surface with a thin border, no elevation.
ShapeBorder _menuShape() =>
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(XRadius.l), side: BorderSide(color: XColors.lineStrong));

/// The menu at a pointer position (a right click on a list row).
Future<void> showChatMenuAt(BuildContext context, ContactInfo c, ThreadKey k, Offset global) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final a = await showMenu<ChatAction>(
    context: context,
    position: RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size),
    items: chatMenuItems(context, c, k),
    constraints: _menuWidth,
    color: XColors.bg1,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shape: _menuShape(),
  );
  if (a != null && context.mounted) await onChatAction(context, c, k, a);
}

/// The ⋮ button with the chat's menu.
class ChatMenuButton extends StatelessWidget {
  const ChatMenuButton(this.c, this.k, {super.key, this.size = 18});
  final ContactInfo c;
  final ThreadKey k;
  final double size;

  @override
  Widget build(BuildContext context) => PopupMenuButton<ChatAction>(
        key: Key('chat-menu-${chatKeyId(c, k)}'),
        tooltip: context.l.chatMenuTooltip,
        position: PopupMenuPosition.under,
        constraints: _menuWidth,
        color: XColors.bg1,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: _menuShape(),
        icon: Icon(Icons.more_vert_rounded, size: size, color: XColors.textDim),
        itemBuilder: (ctx) => chatMenuItems(ctx, c, k),
        onSelected: (a) => onChatAction(context, c, k, a),
      );
}

/// For widget keys: `<contact>-person` or `<contact>-agent-<name>`.
String chatKeyId(ContactInfo c, ThreadKey k) => '${c.label}-${k.id}';

/// Names a chat with an agent; the name stays on this computer.
Future<void> showChatRename(BuildContext context, ContactInfo c, ThreadKey k) async {
  final m = AppScope.read(context);
  final current = m.chatName(c.linkId, k);
  // `""` removes the name; `null` is Cancel
  final name = await showXDialog<String>(context, (ctx) => _ChatRenameDialog(c, k, current: current));
  if (name == null || name == (current ?? '') || !context.mounted) return;
  final err = await m.renameChat(c.linkId, k, name);
  if (err != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
  }
}

/// The rename dialog owns its field's controller: the route still draws the field while it closes.
class _ChatRenameDialog extends StatefulWidget {
  const _ChatRenameDialog(this.c, this.k, {required this.current});
  final ContactInfo c;
  final ThreadKey k;
  final String? current;

  @override
  State<_ChatRenameDialog> createState() => _ChatRenameDialogState();
}

class _ChatRenameDialogState extends State<_ChatRenameDialog> {
  late final _ctl = TextEditingController(text: widget.current ?? '');

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = widget.c;
    return XDialogShell(
      title: l.chatRenameTitle,
      icon: Icons.edit_outlined,
      width: 440,
      actions: [
        if (widget.current != null)
          TextButton(
            key: const Key('chat-rename-reset'),
            onPressed: () => Navigator.pop(context, ''),
            child: Text(l.chatRenameReset),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          key: const Key('chat-rename-ok'),
          onPressed: () => Navigator.pop(context, _ctl.text.trim()),
          child: Text(l.commonSave),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: const Key('chat-rename-field'),
          controller: _ctl,
          autofocus: true,
          maxLength: 64,
          style: XText.body,
          decoration: InputDecoration(labelText: l.chatRenameField, counterText: ''),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        const SizedBox(height: 8),
        Text(l.chatRenameNote(c.label), style: XText.bodyDim),
        const SizedBox(height: 4),
        Text(l.chatRenameDefault(l.chatAgentTitle(c.label, widget.k.agent ?? c.label)), style: XText.meta),
      ]),
    );
  }
}

/// "New chat with an agent": the agents the contacts announced (or that wrote), each opening its chat; one without a
/// chat yet is started (`chat_set`, so the row stays before its first message).
Future<void> showNewChatDialog(BuildContext context) => showXDialog<void>(
      context,
      (ctx) {
        final m = AppScope.of(ctx);
        final l = ctx.l;
        final rows = <Widget>[];
        for (final c in m.contacts) {
          final fresh = m.newChatAgents(c);
          final existing = [for (final k in m.agentChatsOf(c.linkId)) k.agent!];
          final agents = [...existing, ...fresh];
          if (agents.isEmpty) continue;
          rows.add(Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Row(children: [
              XAvatar(c.label, size: 24, agent: c.peerKind == 'agent', picture: m.pictureOfContact(c.linkId)),
              const SizedBox(width: 8),
              Expanded(child: Text(c.label, style: XText.title.copyWith(fontSize: 14))),
              TrustBadge(c.trust, size: 14),
            ]),
          ));
          for (final a in agents) {
            final k = ThreadKey.agent(a);
            final isNew = fresh.contains(a);
            rows.add(_NewChatRow(
              key: Key('new-chat-${chatKeyId(c, k)}'),
              agent: AgentRef(a, contact: c.label, linkId: c.linkId),
              title: chatTitle(l, m, c, k, withContact: false),
              action: isNew ? l.chatNewStart : l.chatNewOpen,
              onTap: () async {
                Navigator.pop(ctx);
                if (isNew && m.chatsSupported) {
                  final err = await m.createChat(c.linkId, a);
                  if (err != null) {
                    if (context.mounted) {
                      ScaffoldMessenger.maybeOf(context)
                          ?.showSnackBar(SnackBar(content: Text(describeError(context.l, err))));
                    }
                    return;
                  }
                }
                await m.select(c.linkId, chat: k);
              },
            ));
          }
        }
        return XDialogShell(
          title: l.chatNewTitle,
          icon: Icons.forum_outlined,
          subtitle: l.chatNewSubtitle,
          width: 480,
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.commonClose))],
          child: rows.isEmpty
              ? Padding(
                  key: const Key('new-chat-empty'),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(l.chatNewEmpty, style: XText.bodyDim),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
                  ),
                ),
        );
      },
    );

class _NewChatRow extends StatelessWidget {
  const _NewChatRow({super.key, required this.agent, required this.title, required this.action, required this.onTap});
  final AgentRef agent;
  final String title;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(XRadius.m),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 8, 8),
          child: Row(children: [
            AgentAvatar(agent, size: 24),
            const SizedBox(width: 8),
            Expanded(child: Text(title, overflow: TextOverflow.ellipsis, style: XText.body)),
            Text(action, style: XText.label.copyWith(color: XColors.accent)),
          ]),
        ),
      );
}

/// The system notification of a new message in a chat: the chat's name only (the local name, or the contact and the
/// agent), never the text (SPEC §11: it may show on a locked screen).
(String, String) messageNotification(AppLocalizations l, AppModel m, ContactInfo c, ThreadKey k) =>
    (l.notifyMessageTitle, l.notifyMessageBody(chatTitle(l, m, c, k)));
