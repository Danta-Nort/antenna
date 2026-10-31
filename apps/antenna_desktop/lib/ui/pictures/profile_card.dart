// SPDX-License-Identifier: AGPL-3.0-only
// Settings → Profile: the owner's picture (CONTROL §28) in one line: the picture as contacts see it, what it is, the
// "?" with what travels to contacts, Change… (the picker) and Remove. A daemon without pictures: the line says a newer
// daemon is needed and the buttons are disabled.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/popover.dart';
import '../widgets/section_page.dart';
import '../widgets/x_buttons.dart';
import 'picture_picker.dart';

class ProfilePictureCard extends StatelessWidget {
  const ProfilePictureCard({super.key});

  Future<void> _remove(BuildContext context) async {
    final m = AppScope.read(context);
    final l = context.l;
    try {
      await m.setPicture(remove: true);
    } on XClientException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describePictureError(l, e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final can = m.picturesSupported;
    final e = m.ownPictureEntry();
    final has = e != null && (e.drawn != null || e.photo != null);
    return SectionCard(
      key: const Key('profile-card'),
      child: Row(children: [
        const CurrentPicture(key: Key('profile-picture'), size: 64),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(l.profilePicture, style: XText.title)),
              const SizedBox(width: 8),
              HelpHint(l.profilePictureHint, id: 'picture', label: l.settingsMoreAbout(l.profilePicture)),
            ]),
            const SizedBox(height: 4),
            Text(
              can ? currentPictureLine(l, m) : l.pictureNeedNewer,
              key: const Key('profile-picture-line'),
              style: XText.bodyDim,
            ),
          ]),
        ),
        const SizedBox(width: 16),
        OutlinedButton(
          key: const Key('profile-picture-change'),
          onPressed: can ? () => showPicturePicker(context) : null,
          child: Text(l.pictureChange),
        ),
        if (has) ...[
          const SizedBox(width: 8),
          TextButton(
            key: const Key('profile-picture-remove'),
            style: XButtons.destructive(),
            onPressed: can ? () => _remove(context) : null,
            child: Text(l.pictureRemove),
          ),
        ],
      ]),
    );
  }
}
