// SPDX-License-Identifier: AGPL-3.0-only
// A local picture for a contact's agent (D-UI-43): "Set picture…" on its chat's menu and on its row in the contact
// card. Unlike `picture_picker.dart` (the owner's own picture, announced to contacts), nothing here ever reaches the
// daemon or the contact: a drawn id is kept as a string, a photo goes through this window's own decode → crop →
// re-encode pipeline (`photo_crop.dart`, the same one already used before a picture ever reaches the daemon) and the
// rebuilt 512 × 512 PNG is kept only in this window's own local settings folder (`chat_prefs.dart`). It overrides
// what the agent's own owner announced everywhere the window shows that agent; "Reset to theirs" undoes it.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/chat_prefs.dart';
import '../../state/pictures.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/agent_logo.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/profile_picture.dart';
import '../widgets/x_buttons.dart';
import 'photo_crop.dart';
import 'picture_picker.dart' show PhotoChooser;

/// Open the local picture picker for [linkId]'s agent [agent] (as the contact announced it).
Future<void> showChatPicturePicker(BuildContext context, {required String linkId, required String agent}) =>
    showXDialog<void>(context, (_) => ChatPicturePicker(linkId: linkId, agent: agent));

class ChatPicturePicker extends StatefulWidget {
  const ChatPicturePicker({super.key, required this.linkId, required this.agent});
  final String linkId;
  final String agent;

  @override
  State<ChatPicturePicker> createState() => _ChatPicturePickerState();
}

class _ChatPicturePickerState extends State<ChatPicturePicker> {
  int? _set;
  String? _error;
  ui.Image? _photo;
  TransformationController? _crop;

  static const _viewport = 320.0;

  @override
  void dispose() {
    _crop?.dispose();
    _photo?.dispose();
    super.dispose();
  }

  Future<void> _choosePhoto() async {
    final l = context.l;
    final path = await PhotoChooser.instance.pick(label: l.pictureImages, confirm: l.pictureChoose);
    if (path == null || !mounted) return;
    setState(() => _error = null);
    String? error;
    ui.Image? image;
    try {
      final f = File(path);
      if (await f.length() > photoMaxBytes) {
        error = l.pictureErrTooLarge;
      } else {
        image = await decodePhoto(await f.readAsBytes());
      }
    } on Object catch (e) {
      debugPrint('chat picture: open the photo: $e');
      error = l.pictureErrOpen;
    }
    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() {
      _error = error;
      if (image != null) {
        _photo?.dispose();
        _crop?.dispose();
        _photo = image;
        _crop = TransformationController(coverMatrix(image, _viewport));
      }
    });
  }

  void _leaveCrop() {
    setState(() {
      _crop?.dispose();
      _photo?.dispose();
      _crop = null;
      _photo = null;
    });
  }

  /// The visible square, rebuilt as a 512 × 512 PNG kept only in this window's own settings folder: never the file
  /// the owner chose, never sent anywhere.
  Future<void> _usePhoto() async {
    final image = _photo;
    final crop = _crop;
    if (image == null || crop == null) return;
    final l = context.l;
    Uint8List? png;
    try {
      png = await renderSquarePng(image, visibleSquare(crop.value, image, _viewport));
    } on Object catch (e) {
      debugPrint('chat picture: render: $e');
    }
    if (!mounted) return;
    if (png == null) {
      setState(() => _error = l.pictureErrStage);
      return;
    }
    AppScope.read(context).setChatPicturePhoto(widget.linkId, widget.agent, png);
    _leaveCrop();
    if (mounted) Navigator.of(context).maybePop();
  }

  void _applyDrawn(String id) {
    AppScope.read(context).setChatPictureDrawn(widget.linkId, widget.agent, id);
    setState(() {});
  }

  void _reset() {
    AppScope.read(context).removeChatPictureOverride(widget.linkId, widget.agent);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final agent = widget.agent;
    final override = m.chatPictureOverride(widget.linkId, agent);
    final image = _photo;
    if (image != null && _crop != null) {
      return XDialogShell(
        key: const Key('chat-picture-picker'),
        title: l.pictureTitleAgent(agent),
        icon: Icons.account_circle_outlined,
        width: 560,
        actions: [
          TextButton(key: const Key('chat-picture-crop-back'), onPressed: _leaveCrop, child: Text(l.pictureBack)),
          FilledButton(
            key: const Key('chat-picture-crop-use'),
            onPressed: _usePhoto,
            child: Text(l.pictureUseThisPhoto),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.pictureCropHint, style: XText.bodyDim),
          const SizedBox(height: 16),
          Center(child: PhotoCropView(image: image, controller: _crop!, viewport: _viewport)),
          if (_error case final e?) ...[const SizedBox(height: 12), _ChatPictureErrorLine(e)],
        ]),
      );
    }
    final sets = m.pictureCatalog?.sets ?? const <PictureSetInfo>[];
    final drawnSet = override is ChatPictureDrawn ? override.id.split('/').first : null;
    final setIndex = (_set ?? sets.indexWhere((s) => s.id == drawnSet)).clamp(0, sets.isEmpty ? 0 : sets.length - 1);
    final set = sets.isEmpty ? null : sets[setIndex];
    return XDialogShell(
      key: const Key('chat-picture-picker'),
      title: l.pictureTitleAgent(agent),
      icon: Icons.account_circle_outlined,
      width: 620,
      actions: [
        OutlinedButton.icon(
          key: const Key('chat-picture-photo'),
          onPressed: _choosePhoto,
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
          label: Text(l.pictureUsePhoto),
        ),
        if (override != null)
          TextButton(
            key: const Key('chat-picture-reset'),
            style: XButtons.destructive(),
            onPressed: _reset,
            child: Text(l.chatPictureReset),
          ),
        FilledButton(
          key: const Key('chat-picture-done'),
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(l.commonDone),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          AgentAvatar(AgentRef(agent, linkId: widget.linkId), size: 64),
          const SizedBox(width: 16),
          Expanded(child: Text(l.chatPictureAbout(agent), style: XText.bodyDim)),
        ]),
        const SizedBox(height: 20),
        if (set != null) ...[
          Row(children: [
            for (final (i, s) in sets.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              _ChatPictureSetTab(s, selected: i == setIndex, onTap: () => setState(() => _set = i)),
            ],
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final a in set.animals)
              _ChatPictureAnimalCell(
                id: '${set.id}/${a.id}',
                name: l.pictureAnimal(a.id.replaceAll('-', '_')),
                current: drawnSet != null && override is ChatPictureDrawn && override.id == '${set.id}/${a.id}',
                onTap: () => _applyDrawn('${set.id}/${a.id}'),
              ),
          ]),
        ],
        if (_error case final e?) ...[const SizedBox(height: 16), _ChatPictureErrorLine(e)],
      ]),
    );
  }
}

class _ChatPictureSetTab extends StatelessWidget {
  const _ChatPictureSetTab(this.set, {required this.selected, required this.onTap});
  final PictureSetInfo set;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = set.coverAsset;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        key: Key('chat-picture-set-${set.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(XRadius.l),
        child: AnimatedContainer(
          duration: XMotion.fast,
          padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
          decoration: BoxDecoration(
            color: selected ? XColors.accentSoft : null,
            borderRadius: BorderRadius.circular(XRadius.l),
            border: Border.all(color: selected ? XColors.accentLine : XColors.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (cover != null) ...[
              Image.asset(cover,
                  width: 48,
                  height: 48,
                  filterQuality: FilterQuality.medium,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 48)),
              const SizedBox(width: 8),
            ],
            Text(
              context.l.pictureSet(set.id),
              style: XText.body.copyWith(color: selected ? XColors.accent : XColors.text, fontWeight: FontWeight.w500),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ChatPictureAnimalCell extends StatelessWidget {
  const _ChatPictureAnimalCell({required this.id, required this.name, required this.current, required this.onTap});
  final String id;
  final String name;
  final bool current;
  final VoidCallback onTap;

  static const size = 64.0;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Tooltip(
      message: name,
      child: Semantics(
        label: current ? '$name, ${l.pictureCurrentMark}' : name,
        button: true,
        selected: current,
        child: InkWell(
          key: Key('chat-picture-cell-$id'),
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size + 8,
            height: size + 8,
            child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
              Container(
                width: size + 8,
                height: size + 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: current ? XColors.accent : Colors.transparent, width: 2),
                ),
              ),
              PictureFace(DrawnPicture(id), size: size, label: name),
              if (current)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    key: Key('chat-picture-current-$id'),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: XColors.accentFill,
                      shape: BoxShape.circle,
                      border: Border.all(color: XColors.bg1, width: 2),
                    ),
                    child: Icon(Icons.check_rounded, size: 12, color: XColors.onAccent),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ChatPictureErrorLine extends StatelessWidget {
  const _ChatPictureErrorLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Row(key: const Key('chat-picture-error'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.error_outline_rounded, size: 16, color: XColors.danger),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: XText.body.copyWith(color: XColors.danger))),
      ]);
}
