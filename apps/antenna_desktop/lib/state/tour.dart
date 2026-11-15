// SPDX-License-Identifier: AGPL-3.0-only
// The first-run tour: a few coach marks over the real screens, shown once after the first unlock of a new node and
// again from Settings → Help (D-151). Its strongest step is the AI apps already on this computer, so it works with
// nothing else at hand; pairing a second device comes last. This file holds the steps and the choice of the app it
// points at; the marks themselves are in ui/home/tour.dart. No text here (the screen words it).

import 'package:flutter/foundation.dart';

import 'ai_apps.dart';
import 'ai_apps_model.dart';

/// The steps in order. [answers] is shown only while an agent runs in Code mode, since only then is there a terminal
/// in the window where it answers.
enum TourStep { chats, aiApps, answers, invite }

/// What the tour asks the owner to press next to the app it points at.
enum TourAppAction { start, connect, setUp }

/// Whether the tour is on screen and at which step. The home screen follows [step] (it opens the section the step is
/// about); the coach mark reads it.
class Tour extends ChangeNotifier {
  TourStep? _step;

  /// Agents the daemon listed when the AI apps step opened: one more means the owner connected one there.
  int agentsAtAiApps = 0;

  TourStep? get step => _step;
  bool get active => _step != null;

  void start() {
    _step = TourStep.chats;
    notifyListeners();
  }

  /// Go to the next step; [answers] whether the Code mode step applies now. Past the last step, the tour ends.
  void next({required bool answers}) {
    final s = _step;
    if (s == null) return;
    _step = switch (s) {
      TourStep.chats => TourStep.aiApps,
      TourStep.aiApps => answers ? TourStep.answers : TourStep.invite,
      TourStep.answers => TourStep.invite,
      TourStep.invite => null,
    };
    notifyListeners();
  }

  /// Skip, Escape, or Done on the last step.
  void close() {
    if (_step == null) return;
    _step = null;
    notifyListeners();
  }
}

/// The steps the tour has right now, for the "2 of 4" count.
List<TourStep> tourSteps({required bool answers}) =>
    [TourStep.chats, TourStep.aiApps, if (answers) TourStep.answers, TourStep.invite];

/// A node is new to the tour when it has nothing yet: no contacts, no agents, no local agents. A node that already has
/// any of them was in use before this window had a tour (an update), and never sees it on its own.
bool freshForTour({required int contacts, required int agents, required int localAgents}) =>
    contacts == 0 && agents == 0 && localAgents == 0;

/// The app the AI apps step points at, and what to press: with Code mode ([code]), a terminal agent the window can run
/// first (Claude Code, then Codex: the strongest way in), then the first found app that is not connected yet. `null`
/// when nothing was found here, or everything found is connected already.
(AiAppRow, TourAppAction)? tourApp(List<AiAppRow> rows, {required bool code}) {
  TourAppAction? action(AiAppRow r) {
    if (!r.found) return null;
    if (code && r.app.terminal != null) return TourAppAction.start;
    // A connected app's button says Reconnect: nothing for a first run to press.
    if (r.connected) return null;
    return r.app.route != ConnectRoute.guide && r.app.config != null ? TourAppAction.connect : TourAppAction.setUp;
  }

  for (final id in code ? const [AiApp.claudeCode, AiApp.codex] : const <AiApp>[]) {
    for (final r in rows) {
      if (r.app.id != id) continue;
      if (action(r) case final a?) return (r, a);
    }
  }
  for (final r in rows) {
    if (action(r) case final a?) return (r, a);
  }
  return null;
}
