// SPDX-License-Identifier: AGPL-3.0-only
// Composer: text → `antenna send`, `/command` → a daemon action. Enter sends, Shift+Enter inserts a new line. The
// commands are offered only once the owner types "/" (reference v3: the field, the paperclip and Send, nothing else).
// Files (the paperclip, a drop, a pasted image) wait above the field as chips and leave only on Send: first the files,
// one `share_file` each in order, then the text as their caption (messengers show the caption under the media, and it
// never arrives without them: when a file is refused, it stays on its chip with the reason and the caption waits).
// Paste: text always goes into the field (at the cursor, replacing the selection), also when the clipboard holds an
// image next to it (a cell from a spreadsheet, a selection from a word processor); an image alone becomes a chip.
// Text from dictation apps arrives through `PasteBridge`. Each chat has its own composer and draft (drafts.dart): the
// text, the files and the To and topic choices stay with the chat they were made in. Text longer than one message holds (64 KiB of UTF-8) goes
// as a `.txt` file in the same chat (long_text.dart): a quiet counter near the limit, and over it a line that says so
// and Send turned into "Send as a file", also right after a paste.
// In an agent's chat of an own computer (∞) a toggle next to Send makes the next message urgent: it interrupts what
// that agent is doing (CONTROL §33, experimental; state/urgent.dart). A long press on Send sends urgently too. The
// toggle belongs to one chat and recipient, and turns itself off after each send.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../host/outgoing_staging.dart';
import '../../host/paste.dart';
import '../../l10n/l10n.dart';
import '../../state/format.dart';
import '../../state/long_text.dart';
import '../../state/messages.dart';
import '../../state/threads.dart';
import '../../state/trust.dart' show trustGlyph;
import '../../state/urgent.dart';
import '../../theme/x_theme.dart';
import '../agents/agents_dialog.dart';
import '../app_scope.dart';
import '../approvals/approvals_view.dart';
import '../files/file_actions.dart';
import '../files/file_card.dart' show fileSizeLabel;
import '../pairing/pairing_dialogs.dart';
import '../security/owner_confirm.dart';
import '../widgets/self_level.dart';
import '../widgets/x_buttons.dart';
import 'address_line.dart';
import 'attachments.dart';
import 'slash_commands.dart';

class Composer extends StatefulWidget {
  const Composer({super.key});

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  String? _hint;

  /// The chat this composer writes in (the chat view keys a composer per chat): its draft is kept as it is typed.
  String? _link;
  ThreadKey _chat = ThreadKey.person;

  /// A Send is in progress (files are being shared): a second Enter does not start another.
  bool _sending = false;

  /// The field's text in bytes of UTF-8 (what one message is limited by).
  int _bytes = 0;

  /// "Urgent: interrupt now" is on for this chat and recipient (`<link>/<recipient>`); `null`: off.
  String? _urgentFor;

  static String _urgentKey(String linkId, Recipient r) => '$linkId/${r.id}';

  @override
  void initState() {
    super.initState();
    // Text from dictation apps and Edit > Paste on macOS (the Runner catches what Flutter drops).
    PasteBridge.instance.attach();
    final m = AppScope.read(context);
    _link = m.selected?.linkId;
    if (_link case final link?) {
      _chat = m.openThreadOf(link);
      _text.text = m.draftTextOf(link, _chat);
      _bytes = utf8Length(_text.text);
    }
    _text.addListener(() {
      setState(() {
        _hint = null;
        _bytes = utf8Length(_text.text);
      });
      if (_link case final link?) m.setDraftText(link, _chat, _text.text);
    });
    _focus.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        unawaited(_submit());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Cmd+V / Ctrl+V with no text on the clipboard: an image becomes an attachment of the selected link. With text the
  /// field's own paste has already inserted it.
  Future<void> _pasteImage() async {
    final m = AppScope.read(context);
    final link = m.selected?.linkId;
    if (link == null || await Clipboard.hasStrings()) return;
    final bytes = await ClipboardImages.instance.read();
    if (bytes == null || bytes.isEmpty || !mounted) return;
    // Two pastes within a second get different names: the contact sees two files.
    final names = {for (final a in m.stagedOf(link)) a.name};
    final first = stagedImageName(DateTime.now());
    var name = first;
    for (var i = 2; names.contains(name); i++) {
      name = first.replaceFirst(RegExp(r'\.png$'), '-$i.png');
    }
    final s = OutgoingStaging.instance?.stageBytes(bytes, name);
    if (s == null) {
      setState(() => _hint = context.l.composerPasteFailed);
      return;
    }
    m.stageAttachment(link, s);
  }

  /// What the composer offers for urgent in the open chat (and for whom).
  (UrgentOffer, Recipient?) _offer() {
    final m = AppScope.read(context);
    final c = m.selected;
    if (c == null) return (UrgentOffer.hidden, null);
    final r = m.recipientOf(c.linkId);
    return (urgentOffer(c, r, daemonProto: m.daemonProto), r);
  }

  /// [urgent]: a long press on Send. Otherwise the toggle decides, when it is on for this chat and recipient.
  Future<void> _submit({bool urgent = false}) async {
    if (_sending) return;
    final raw = _text.text;
    final m = AppScope.read(context);
    final link = m.selected?.linkId;
    final command = raw.trim().startsWith('/') && !raw.trim().startsWith('//');
    if (link != null && !command && m.stagedOf(link).isNotEmpty) {
      // The files first; the caption only when all of them went (a refused one keeps its chip and the caption).
      setState(() => _sending = true);
      final sent = await m.sendStaged(link);
      if (!mounted) return;
      setState(() => _sending = false);
      // Another chat was opened while the files went: the caption is not theirs, it stays in this chat's draft.
      if (!sent || m.selected?.linkId != link || m.openThreadOf(link) != _chat) return;
    }
    if (raw.trim().isEmpty) return;
    final l = context.l;
    if (link != null && textTooLong(raw)) {
      // Longer than one message holds: a text file in this chat, with this chat's address. A refused file keeps its
      // chip with the reason, as any file in the composer.
      if (_text.text == raw) _text.clear();
      setState(() => _sending = true);
      final r = await m.sendTextAsFile(link, raw);
      if (!mounted) return;
      setState(() => _sending = false);
      if (r == TextFileResult.notWritten) {
        if (_text.text.isEmpty) _text.text = raw;
        setState(() => _hint = l.composerTextFileFailed);
      }
      return;
    }
    final slash = parseSlash(raw);
    if (slash == null) {
      if (command) {
        setState(() => _hint = l.composerNoSuchCommand);
        return;
      }
      // Typed while the files were being sent: kept for the next Send.
      if (_text.text == raw) _text.clear();
      final (offer, to) = _offer();
      final asUrgent = offer == UrgentOffer.available &&
          to != null &&
          (urgent || _urgentFor == _urgentKey(link ?? '', to));
      // Urgent is for this one message.
      if (_urgentFor != null) setState(() => _urgentFor = null);
      final contact = m.selected?.label ?? '';
      final r = await m.send(raw.trim().startsWith('//') ? raw.trim().substring(1) : raw, urgent: asUrgent);
      // Their Antenna could not take the flag: the message went, as a normal one.
      if (asUrgent && r?.urgent == false && mounted) setState(() => _hint = l.composerUrgentFellBack(contact));
      return;
    }
    if (slash.error != null) {
      setState(() => _hint = '${slash.command.name}: ${slash.errorText(l)}');
      return;
    }
    _text.clear();
    switch (slash.command.kind) {
      case SlashKind.invite:
        await showInviteDialog(context, trust: slash.trust, ttl: slash.ttl, label: slash.label);
      case SlashKind.join:
        await showJoinDialog(context, link: slash.link);
      case SlashKind.trust:
        final c = m.selected;
        if (c == null) return;
        // Level 5 is for the owner's own computers: accept that first, then the password, as in the picker.
        if (slash.trust == 5 && c.trust != 5 && !await confirmSelfLevel(context)) return;
        if (!mounted) return;
        final (done, err) = await confirmOwner(
          context,
          action: l.trustChangeAction(c.label, trustGlyph(c.trust), trustGlyph(slash.trust!)),
          cli: 'antenna trust ${c.label} ${slash.trust}',
          run: (auth) => m.setTrust(c.linkId, slash.trust!, auth),
        );
        if (!done && err == null) return;
        m.addLocalNote(err == null
            ? l.composerNoteTrust(c.label, slash.trust!, m.selected?.netMode ?? '—')
            : 'antenna trust → ${describeError(l, err)}');
      case SlashKind.agent:
        await showAgentsDialog(context);
      case SlashKind.approvals:
        await m.refreshApprovals();
        if (mounted) await showApprovalsDialog(context);
      case SlashKind.pairings:
        await m.refreshPairings();
        final p = m.pendingInvites;
        m.addLocalNote(p.isEmpty
            ? l.composerNoteNoInvites
            : 'antenna pairing → ${p.map((i) => '${i.label ?? i.id}: ${i.phase}').join(' · ')}');
      case SlashKind.log:
        final c = m.selected;
        if (c == null) return;
        try {
          final log = await m.daemon.log(c.linkId, limit: 10);
          m.addLocalNote(log.isEmpty
              ? l.composerNoteLogEmpty(c.label)
              : 'antenna log ${c.label} → ${log.map((r) => '${hhmm(DateTime.fromMillisecondsSinceEpoch(r.ts))} ${r.actor} '
                  '${r.action}: ${r.decision}').join(' · ')}');
        } on Object catch (e) {
          m.addLocalNote('antenna log → ${describeError(l, e)}');
        }
      case SlashKind.contacts:
        await m.refreshContacts();
        m.addLocalNote(l.composerNoteContacts(m.contacts.length));
      case SlashKind.status:
        final st = await m.refreshStatus();
        if (st != null) {
          m.addLocalNote('antenna status → ${st.daemon} · ${l.gateFooterProtocol(st.protocol)} · ${m.hello?.proto ?? ''} · '
              '${st.state.name} · relay ${st.relay} · ${st.links == null ? l.composerContactsUnknown : l.navContactsCount(st.links!)}');
        }
      case SlashKind.lock:
        await m.lock();
    }
    _focus.requestFocus();
  }

  Widget _sendButton(String? tooltip) => IconButton(
        key: const Key('send'),
        tooltip: tooltip,
        onPressed: _submit,
        style: XButtons.primary().copyWith(
          shape: const WidgetStatePropertyAll(CircleBorder()),
          minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        ),
        icon: Icon(Icons.arrow_upward_rounded, size: 20, color: XColors.onAccent),
      );

  void _insert(SlashCommand c) {
    _text.text = '${c.name} ';
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = SlashCommand.matching(_text.text.contains(' ') ? '' : _text.text);
    final m = AppScope.of(context);
    final contact = m.selected;
    final to = contact == null ? null : m.recipientOf(contact.linkId);
    final offer =
        contact == null || to == null ? UrgentOffer.hidden : urgentOffer(contact, to, daemonProto: m.daemonProto);
    final urgentOn = offer == UrgentOffer.available && _urgentFor == _urgentKey(contact!.linkId, to!);
    final l = context.l;
    final over = _bytes > maxMessageBytes;
    final limit = fileSizeLabel(maxMessageBytes);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (suggestions.isNotEmpty) _Suggestions(suggestions, onPick: _insert),
        if (_hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(_hint!, style: XText.meta.copyWith(color: XColors.warn)),
          ),
        if (_bytes >= messageCounterFrom)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
            child: Row(children: [
              if (over)
                Expanded(
                  child: Text(l.composerTooLongHint(limit),
                      key: const Key('composer-too-long'), style: XText.meta.copyWith(color: XColors.textDim)),
                )
              else
                const Spacer(),
              const SizedBox(width: 8),
              Text(l.composerTextCounter(fileSizeLabel(_bytes), limit),
                  key: const Key('composer-counter'),
                  style: XText.meta.copyWith(color: over ? XColors.warn : XColors.textMute)),
            ]),
          ),
        if (contact != null) StagedAttachments(contact),
        if (contact != null) AddressLine(contact),
        if (urgentOn) _UrgentLine(agent: to.agent!),
        AnimatedBuilder(
          animation: _focus,
          builder: (context, child) => AnimatedContainer(
            duration: XMotion.fast,
            decoration: BoxDecoration(
              color: XColors.bg2,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: urgentOn ? XColors.danger : (_focus.hasFocus ? XColors.accentLine : XColors.line),
                  width: _focus.hasFocus || urgentOn ? 1.5 : 1),
            ),
            child: child,
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: IconButton(
                key: const Key('attach'),
                tooltip: context.l.composerAttach,
                onPressed: () => pickAndAttach(context),
                icon: Icon(Icons.attach_file_rounded, size: 20, color: XColors.textDim),
              ),
            ),
            if (contact != null) TopicPicker(contact),
            Expanded(
              child: Actions(
                actions: {PasteTextIntent: _PasteAction(_pasteImage)},
                child: TextField(
                  key: const Key('composer'),
                  controller: _text,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  style: XText.body,
                  decoration: InputDecoration(
                    hintText: context.l.composerHint,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  ),
                ),
              ),
            ),
            if (offer != UrgentOffer.hidden && !over)
              _UrgentToggle(
                offer: offer,
                on: urgentOn,
                agent: to!.agent!,
                contact: contact!.label,
                onChanged: (v) => setState(() => _urgentFor = v ? _urgentKey(contact.linkId, to) : null),
              ),
            if (over)
              Padding(
                padding: const EdgeInsets.all(4),
                child: FilledButton.icon(
                  key: const Key('send-as-file'),
                  onPressed: _sending ? null : _submit,
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: Text(l.composerSendAsFile),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(4),
                child: offer == UrgentOffer.available
                    // A long press sends urgently where urgent is offered (CONTROL §33): the press is Send's, so the
                    // tooltip shows on hover only.
                    ? Tooltip(
                        message: context.l.composerSendOrUrgent,
                        triggerMode: TooltipTriggerMode.manual,
                        child: GestureDetector(
                          onLongPress: () => unawaited(_submit(urgent: true)),
                          child: _sendButton(null),
                        ),
                      )
                    : _sendButton(context.l.composerSend),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// "Urgent: interrupt now" next to Send: off, on (red), or shown but off when the contact's Antenna is older.
class _UrgentToggle extends StatelessWidget {
  const _UrgentToggle(
      {required this.offer, required this.on, required this.agent, required this.contact, required this.onChanged});
  final UrgentOffer offer;
  final bool on;
  final String agent;
  final String contact;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final older = offer == UrgentOffer.olderPeer;
    final base = XButtons.icon();
    return IconButton(
      key: const Key('composer-urgent'),
      tooltip: older
          ? '${l.composerUrgent}\n${l.composerUrgentOlder(contact)}'
          : '${l.composerUrgent} · ${l.experimentalTag}\n'
              '${on ? l.composerUrgentOnTip(agent) : l.composerUrgentTip(agent)}',
      isSelected: on,
      onPressed: older ? null : () => onChanged(!on),
      style: on
          ? base.copyWith(
              backgroundColor: WidgetStatePropertyAll(XColors.dangerHover),
              foregroundColor: WidgetStatePropertyAll(XColors.danger),
              side: WidgetStatePropertyAll(BorderSide(color: XColors.danger.withValues(alpha: 0.45))),
            )
          : base,
      icon: Icon(on ? Icons.bolt_rounded : Icons.bolt_outlined, size: 20),
    );
  }
}

/// Above the field while urgent is on: what Send will do.
class _UrgentLine extends StatelessWidget {
  const _UrgentLine({required this.agent});
  final String agent;

  @override
  Widget build(BuildContext context) => Padding(
        key: const Key('composer-urgent-on'),
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Row(children: [
          Icon(Icons.bolt_rounded, size: 14, color: XColors.danger),
          const SizedBox(width: 4),
          Flexible(child: Text(context.l.composerUrgentOn(agent), style: XText.meta.copyWith(color: XColors.danger))),
        ]),
      );
}

/// Paste in the composer: the field's own paste first (text at the cursor, replacing the selection; nothing without
/// text), then [onImage], which attaches an image only when the clipboard has no text.
class _PasteAction extends ContextAction<PasteTextIntent> {
  _PasteAction(this.onImage);
  final Future<void> Function() onImage;

  @override
  Object? invoke(PasteTextIntent intent, [BuildContext? context]) {
    callingAction?.invoke(intent);
    unawaited(onImage());
    return null;
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions(this.items, {required this.onPick});
  final List<SlashCommand> items;
  final ValueChanged<SlashCommand> onPick;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: xPanel(fill: XColors.bg1, border: XColors.line, radius: XRadius.l, glow: 1),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final c in items)
            InkWell(
              onTap: () => onPick(c),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  SizedBox(
                    width: 92,
                    child: Text(c.name, style: XText.monoStrong.copyWith(color: XColors.accent)),
                  ),
                  Expanded(
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: c.help(context.l), style: XText.body.copyWith(fontSize: 12)),
                      if (c.args(context.l).isNotEmpty) TextSpan(text: '   ${c.args(context.l)}', style: XText.monoSmall),
                    ])),
                  ),
                  Text(c.cli, style: XText.monoSmall),
                ]),
              ),
            ),
        ]),
      );
}
