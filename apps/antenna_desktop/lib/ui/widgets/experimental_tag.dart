// SPDX-License-Identifier: AGPL-3.0-only
// The "Experimental" tag (D-94): a mechanism of our own design ships marked experimental until it has had its review
// and time in use. Of those in this preview, the window shows addressing and topics, task authority and the Code mode
// wake (resident agents and `share_file_content` have no controls here). A quiet pill next to the control or its
// heading, once, never on every repeated row; the tooltip says what it means. Neutral colors on purpose: it is not a
// warning (amber), a selection (accent) or an agent (violet); and never dashed (dashes read as disappearing messages).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/x_theme.dart';

class ExperimentalTag extends StatelessWidget {
  const ExperimentalTag({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Tooltip(
      message: l.experimentalTip,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
        decoration: BoxDecoration(
          // Its own fill, so the text keeps its contrast on any surface (textDim on bg2, contrast test).
          color: XColors.bg2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: XColors.lineStrong),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.science_outlined, size: 11, color: XColors.textDim),
          const SizedBox(width: 4),
          Text(
            l.experimentalTag,
            style: XText.meta.copyWith(fontSize: 11, height: 1.25, color: XColors.textDim, fontWeight: FontWeight.w600),
          ),
        ]),
      ),
    );
  }
}
