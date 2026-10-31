// SPDX-License-Identifier: AGPL-3.0-only
// Pictures of the agents in a conversation that reads like a group chat (D-UI-24): each agent message carries its
// agent's picture, and one of this node's agents that runs on this computer carries a "this Mac" mark. The picture
// follows the rule of the marks (D-UI-18): the mark of the AI only for the owner's own agent and only from a fact the
// window has (the CLI it started in Code mode, or the AI app it connected); everything else, a contact's agent above
// all, gets a neutral monogram, since a contact chooses its agents' names and a name proves nothing. A profile picture
// (CONTROL §28) comes ahead of both: the one the owner chose for their agent, or the one a contact announced for its
// agent in that link (the daemon keys it by the link, never by a name alone), always with the agent badge.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/app_model.dart';
import '../../state/appearance.dart';
import '../../state/chat_prefs.dart';
import '../../state/pictures.dart';
import '../../theme/ai_logos.dart';
import '../../theme/x_theme.dart';
import '../app.dart' show AppearanceScope;
import '../app_scope.dart';
import 'agent_logo.dart';
import 'ai_logo.dart';
import 'profile_picture.dart';

/// What an agent's picture is drawn from: a profile picture (a drawn one, or a photo the daemon rebuilt) the owner
/// chose for their agent or the contact announced for its agent; else the AI's mark the window knows; else a neutral
/// monogram.
sealed class AgentPicture {
  const AgentPicture();
}

/// A drawn picture of the bundled sets.
final class AgentDrawnPicture extends AgentPicture {
  const AgentDrawnPicture(this.picture);
  final DrawnPicture picture;
}

/// A photo, from the daemon's rebuilt bytes.
final class AgentPhotoPicture extends AgentPicture {
  const AgentPhotoPicture(this.picture);
  final PhotoPicture picture;
}

/// The mark of the AI app or CLI one of this node's agents runs on ([knownAgentBrand]).
final class AgentLogoPicture extends AgentPicture {
  const AgentLogoPicture(this.brand);
  final AiBrand brand;
}

/// The initials of the agent's name on a neutral tile, with the small agent badge.
final class AgentMonogramPicture extends AgentPicture {
  const AgentMonogramPicture();
}

/// The picture for [agent]: its profile picture ([chosen]) first; else its AI's mark only when it is mine and the brand
/// is known with a mark we may draw.
AgentPicture agentPictureOf(AgentRef agent, {ShownPicture? chosen}) {
  switch (chosen) {
    case DrawnPicture():
      return AgentDrawnPicture(chosen);
    case PhotoPicture():
      return AgentPhotoPicture(chosen);
    case null:
      break;
  }
  final brand = agent.mine ? agent.brand : null;
  if (brand != null && aiMarks.containsKey(brand)) return AgentLogoPicture(brand);
  return const AgentMonogramPicture();
}

/// One of this node's agents runs on this computer, as a fact the window has: it was started in this window's
/// terminal (Code mode, in this session or remembered from an earlier one), or an AI app's configuration on this
/// computer names it. An agent that only holds a token is not marked: the window cannot tell where it runs.
bool agentOnThisComputer(AppModel m, String agent, {Appearance? look}) =>
    m.runOf(agent) != null || look?.agentRun(agent) != null || m.appConfiguredHere(agent);

/// "this Mac" on macOS, "this computer" elsewhere.
String thisComputerLabel(BuildContext context, AppModel? m) =>
    (m?.agentHost?.macos ?? Platform.isMacOS) ? context.l.authorThisMac : context.l.authorThisComputer;

/// The profile picture of [agent] as the window may draw it: mine by its name; a contact's agent shows the local
/// override this computer set for it first (D-UI-43, a phone book entry: "Set picture…" on its chat, its card),
/// else the picture the contact's agent's own owner announced, by the link and the name the contact announced.
ShownPicture? agentProfilePicture(AppModel? m, AgentRef agent) {
  if (m == null) return null;
  if (agent.mine) return m.pictureOfMine(agent: agent.name);
  final link = agent.linkId;
  final contact = agent.contact;
  final override = link != null
      ? m.chatPictureOverride(link, agent.name)
      : (contact == null ? null : m.chatPictureOverrideByLabel(contact, agent.name));
  final shown = switch (override) {
    ChatPictureDrawn(:final id) => DrawnPicture(id),
    ChatPicturePhoto(:final file) => switch (m.chatPhotoBytes(file)) {
        final bytes? => PhotoPicture(file, bytes),
        null => null,
      },
    null => null,
  };
  if (shown != null) return shown;
  if (link != null) return m.pictureOfContact(link, agent: agent.name);
  return contact == null ? null : m.pictureOfContactLabel(contact, agent: agent.name);
}

/// An agent's avatar in the conversation.
class AgentAvatar extends StatelessWidget {
  const AgentAvatar(this.agent, {super.key, this.size = 28});
  final AgentRef agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.maybeOf(context);
    final ref = agent.mine && agent.brand == null && m != null
        ? AgentRef(agent.name,
            mine: true, brand: knownAgentBrand(m, agent.name, look: AppearanceScope.maybeOf(context)))
        : agent;
    return switch (agentPictureOf(ref, chosen: agentProfilePicture(m, agent))) {
      AgentDrawnPicture(:final picture) => PictureFace(picture, size: size, label: agent.name, agentBadge: true),
      AgentPhotoPicture(:final picture) => PictureFace(picture, size: size, label: agent.name, agentBadge: true),
      AgentLogoPicture(:final brand) => AiLogo(brand: brand, label: agent.name, size: size, circle: true),
      AgentMonogramPicture() => _Monogram(agent.name, size: size),
    };
  }
}

/// Initials on a neutral tile; the small badge says "an agent" (a person's initials sit on a colored tile instead).
class _Monogram extends StatelessWidget {
  const _Monogram(this.name, {required this.size});
  final String name;
  final double size;

  static String initials(String s) {
    final parts = s.trim().split(RegExp(r'[\s_\-./·•|]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
    return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final badge = (size * 0.46).roundToDouble();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: XColors.isDark ? XColors.bg3 : XColors.bg2,
            shape: BoxShape.circle,
            border: Border.all(color: XColors.lineStrong),
          ),
          child: Text(
            initials(name),
            style: XText.label.copyWith(fontSize: size * 0.36, height: 1, color: XColors.textDim, fontWeight: FontWeight.w600),
          ),
        ),
        Positioned(
          right: -2,
          bottom: -2,
          child: AgentBadge(size: badge, key: const Key('agent-mark-generic')),
        ),
      ]),
    );
  }
}

/// The "this Mac" mark after the name of one of my agents that runs here.
class ThisComputerTag extends StatelessWidget {
  const ThisComputerTag({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.maybeOf(context);
    return Tooltip(
      message: context.l.authorLocalTip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: XColors.bg2,
          borderRadius: BorderRadius.circular(XRadius.s),
          border: Border.all(color: XColors.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.laptop_mac_rounded, size: 12, color: XColors.textDim),
          const SizedBox(width: 4),
          Text(thisComputerLabel(context, m), style: XText.meta.copyWith(color: XColors.textDim)),
        ]),
      ),
    );
  }
}
