// SPDX-License-Identifier: AGPL-3.0-only
// The picture picker (CONTROL §28): the owner's own picture ("Your picture") or one of the owner's agents' ("Picture
// for <name>"). A tab per drawn set of the bundled manifest, a grid of its animals with the current one marked; a click
// applies at once (`picture_set {drawn}`). "Use my photo…" opens a file, the crop step shows it in a square to move and
// zoom, and "Use photo" hands the daemon a 512 × 512 PNG of the visible square from the window's staging folder (never
// the original file, and never a protected folder the daemon may not read on macOS); the staged file is deleted when
// the daemon has answered. The picture shown afterwards is the daemon's rebuilt photo, as for everybody else. A daemon
// without pictures: everything is disabled with "Needs a newer Antenna daemon on this computer".

import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';

import '../../host/outgoing_staging.dart';
import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/messages.dart';
import '../../state/pictures.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/agent_logo.dart' show knownAgentBrand;
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/profile_picture.dart';
import '../widgets/x_buttons.dart';
import 'photo_crop.dart';

/// Choosing a photo file through the system dialog. Replaced in tests (`flutter test` has no plugins).
abstract class PhotoChooser {
  /// [label] names the image filter, [confirm] the dialog's button.
  Future<String?> pick({required String label, required String confirm});

  static PhotoChooser instance = _SystemPhotoChooser();
}

class _SystemPhotoChooser implements PhotoChooser {
  @override
  Future<String?> pick({required String label, required String confirm}) async => (await fs.openFile(
        acceptedTypeGroups: [
          fs.XTypeGroup(
            label: label,
            extensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic'],
            uniformTypeIdentifiers: const ['public.image'],
          ),
        ],
        confirmButtonText: confirm,
      ))
          ?.path;
}

/// A `picture_set` error in plain words.
String describePictureError(AppLocalizations l, Object e) => switch (e) {
      XControlException(code: XErrorCode.pictureRefused) => l.pictureErrRefused,
      XControlException(code: XErrorCode.sandboxUnavailable) => l.pictureErrSandbox,
      XControlException(code: XErrorCode.notFound) => l.pictureErrNotFound,
      XControlException(code: XErrorCode.badRequest) => l.pictureErrBad,
      XControlException(code: XErrorCode.unknownCommand) => l.pictureNeedNewer,
      _ => describeError(l, e),
    };

/// Open the picker for the owner, or for the owner's [agent].
Future<void> showPicturePicker(BuildContext context, {String? agent}) =>
    showXDialog<void>(context, (_) => PicturePicker(agent: agent));

/// The current picture of the owner or of the owner's [agent] as it is drawn everywhere, or what stands for none: the
/// agent's mark (its AI's when known, else the Antenna mark), or a neutral person for the owner (the window has no name
/// of its own for the owner, so no initials).
class CurrentPicture extends StatelessWidget {
  const CurrentPicture({super.key, this.agent, this.size = 64});
  final String? agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final picture = m.pictureOfMine(agent: agent);
    final a = agent;
    if (a != null) {
      return XAvatar(a, size: size, agent: true, brand: knownAgentBrand(m, a), picture: picture);
    }
    if (picture != null) return PictureFace(picture, size: size, label: context.l.profilePicture);
    return Container(
      key: const Key('picture-none'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: XColors.isDark ? XColors.bg3 : XColors.bg2,
        shape: BoxShape.circle,
        border: Border.all(color: XColors.lineStrong),
      ),
      child: Icon(Icons.person_outline_rounded, size: size * 0.5, color: XColors.textDim),
    );
  }
}

/// What the current picture is, in words ("Fox · Soft", "A photo", or none).
String currentPictureLine(AppLocalizations l, AppModel m, {String? agent}) {
  final e = m.ownPictureEntry(agent: agent);
  final shown = m.pictureOfMine(agent: agent);
  return switch (shown) {
    DrawnPicture(:final id) => l.pictureCurrentDrawn(
        l.pictureAnimal(id.split('/').last.replaceAll('-', '_')), l.pictureSet(id.split('/').first)),
    PhotoPicture() => l.pictureCurrentPhoto,
    null => e?.photo != null ? l.pictureCurrentPhoto : l.profilePictureNone,
  };
}

class PicturePicker extends StatefulWidget {
  const PicturePicker({super.key, this.agent});

  /// One of the owner's agents; `null`: the owner.
  final String? agent;

  @override
  State<PicturePicker> createState() => _PicturePickerState();
}

class _PicturePickerState extends State<PicturePicker> {
  int? _set;

  /// The id being applied, `remove`, or `photo`.
  String? _busy;
  String? _error;

  /// The crop step: the decoded photo and its viewport's transform.
  ui.Image? _photo;
  TransformationController? _crop;

  static const _viewport = 320.0;

  @override
  void dispose() {
    _crop?.dispose();
    _photo?.dispose();
    super.dispose();
  }

  String? get _agent => widget.agent;

  Future<void> _apply({String? drawn, String? photo, bool remove = false}) async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() {
      _busy = drawn ?? (remove ? 'remove' : 'photo');
      _error = null;
    });
    String? error;
    try {
      await m.setPicture(agent: _agent, drawn: drawn, photo: photo, remove: remove);
    } on XClientException catch (e) {
      error = describePictureError(l, e);
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _error = error;
    });
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
      debugPrint('picture: open the photo: $e');
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

  /// The visible square as a PNG in a folder of its own in the staging root, sent as `picture_set {photo}`; the file
  /// is deleted once the daemon answered, whatever it said.
  Future<void> _usePhoto() async {
    final image = _photo;
    final crop = _crop;
    if (image == null || crop == null) return;
    final l = context.l;
    setState(() {
      _busy = 'photo';
      _error = null;
    });
    final staging = OutgoingStaging.instance;
    StagedFile? staged;
    try {
      final png = await renderSquarePng(image, visibleSquare(crop.value, image, _viewport));
      staged = staging?.stageBytes(png, 'picture.png');
    } on Object catch (e) {
      debugPrint('picture: render the photo: $e');
    }
    if (!mounted) {
      if (staged != null) staging?.release(staged.path);
      return;
    }
    if (staged == null) {
      setState(() {
        _busy = null;
        _error = l.pictureErrStage;
      });
      return;
    }
    try {
      await _apply(photo: staged.path);
    } finally {
      staging?.release(staged.path);
    }
    if (mounted && _error == null) _leaveCrop();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final agent = _agent;
    final title = agent == null ? l.profilePicture : l.pictureTitleAgent(agent);
    final can = m.picturesSupported;
    final entry = m.ownPictureEntry(agent: agent);
    final hasPicture = entry != null && (entry.drawn != null || entry.photo != null);
    final busy = _busy != null;
    final image = _photo;
    if (image != null && _crop != null) {
      return XDialogShell(
        key: const Key('picture-picker'),
        title: title,
        icon: Icons.account_circle_outlined,
        width: 560,
        actions: [
          TextButton(
            key: const Key('picture-crop-back'),
            onPressed: busy ? null : _leaveCrop,
            child: Text(l.pictureBack),
          ),
          FilledButton(
            key: const Key('picture-crop-use'),
            onPressed: busy ? null : _usePhoto,
            child: Text(busy ? l.pictureChecking : l.pictureUseThisPhoto),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.pictureCropHint, style: XText.bodyDim),
          const SizedBox(height: 16),
          Center(child: PhotoCropView(image: image, controller: _crop!, viewport: _viewport)),
          if (_error case final e?) ...[const SizedBox(height: 12), _ErrorLine(e)],
        ]),
      );
    }
    final sets = m.pictureCatalog?.sets ?? const <PictureSetInfo>[];
    final drawnSet = entry?.drawn?.split('/').first;
    final setIndex = (_set ?? sets.indexWhere((s) => s.id == drawnSet)).clamp(0, sets.isEmpty ? 0 : sets.length - 1);
    final set = sets.isEmpty ? null : sets[setIndex];
    return XDialogShell(
      key: const Key('picture-picker'),
      title: title,
      icon: Icons.account_circle_outlined,
      width: 620,
      actions: [
        OutlinedButton.icon(
          key: const Key('picture-photo'),
          onPressed: can && !busy ? _choosePhoto : null,
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
          label: Text(l.pictureUsePhoto),
        ),
        if (hasPicture)
          TextButton(
            key: const Key('picture-remove'),
            style: XButtons.destructive(),
            onPressed: can && !busy ? () => _apply(remove: true) : null,
            child: Text(l.pictureRemove),
          ),
        FilledButton(
          key: const Key('picture-done'),
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(l.commonDone),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CurrentPicture(key: const Key('picture-current'), agent: agent),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(currentPictureLine(l, m, agent: agent), style: XText.title),
              const SizedBox(height: 4),
              Text(agent == null ? l.pictureAboutMine : l.pictureAboutAgent(agent), style: XText.bodyDim),
            ]),
          ),
        ]),
        if (!can) ...[
          const SizedBox(height: 16),
          Row(key: const Key('picture-need-newer'), children: [
            Icon(Icons.info_outline_rounded, size: 16, color: XColors.textDim),
            const SizedBox(width: 8),
            Expanded(child: Text(l.pictureNeedNewer, style: XText.bodyDim)),
          ]),
        ],
        const SizedBox(height: 20),
        if (set != null) ...[
          Row(children: [
            for (final (i, s) in sets.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              _SetTab(s, selected: i == setIndex, onTap: () => setState(() => _set = i)),
            ],
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final a in set.animals)
              _AnimalCell(
                id: '${set.id}/${a.id}',
                name: l.pictureAnimal(a.id.replaceAll('-', '_')),
                current: entry?.drawn == '${set.id}/${a.id}',
                busy: _busy == '${set.id}/${a.id}',
                onTap: can && !busy ? () => _apply(drawn: '${set.id}/${a.id}') : null,
              ),
          ]),
        ],
        if (_error case final e?) ...[const SizedBox(height: 16), _ErrorLine(e)],
      ]),
    );
  }
}

/// A set's tab: its cover icon (transparent) and its name; the name alone for a set without a cover.
class _SetTab extends StatelessWidget {
  const _SetTab(this.set, {required this.selected, required this.onTap});
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
        key: Key('picture-set-${set.id}'),
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

/// One animal of the grid: a ring and a check on the current one; a click applies it.
class _AnimalCell extends StatelessWidget {
  const _AnimalCell({required this.id, required this.name, required this.current, required this.busy, this.onTap});
  final String id;
  final String name;
  final bool current;
  final bool busy;
  final VoidCallback? onTap;

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
          key: Key('picture-cell-$id'),
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
              Opacity(
                opacity: onTap == null && !current ? 0.5 : 1,
                child: PictureFace(DrawnPicture(id), size: size, label: name),
              ),
              if (busy)
                const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              if (current)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    key: Key('picture-current-$id'),
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

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Row(key: const Key('picture-error'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.error_outline_rounded, size: 16, color: XColors.danger),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: XText.body.copyWith(color: XColors.danger))),
      ]);
}
