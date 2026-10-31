// SPDX-License-Identifier: AGPL-3.0-only
// The agents' questions in the window (D-118, PG-18): an agent asks the owner something it cannot decide; the window
// shows the open questions as cards (with the approval requests), notifies when one arrives while the window is in
// the background (facts only: which agent, never the question), and sends the owner's answer or sets the question
// aside. Where an agent's questions go (the owner, or a contact) is set with the owner password. The question is the
// agent's own text, shown quoted as data, with what the agent had read when it asked.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'owner_auth.dart';

mixin EscalationsMixin on ChangeNotifier {
  XDaemon get daemon;

  void safeNotify();

  /// Open questions, newest first.
  List<EscalationInfo> questions = const [];

  /// The daemon answers `escalations` (a daemon from before them does not: the window shows none).
  bool questionsSupported = true;

  /// A question that arrived (not one listed at the start): for the system notification.
  Stream<EscalationInfo> get newQuestions => _newQuestions.stream;
  final _newQuestions = StreamController<EscalationInfo>.broadcast();

  /// The owner answered or set aside one of [agent]'s questions (Code mode types a line for it).
  @protected
  void onQuestionDecided(String agent) {}

  Future<void> refreshQuestions() async {
    try {
      questions = await daemon.escalations();
      questionsSupported = true;
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand) {
        questionsSupported = false;
        questions = const [];
      }
    } on Object {
      return;
    }
    safeNotify();
  }

  /// The subscription's `escalation` event: asked, answered or set aside (here or in another window, the CLI).
  void onEscalationEvent(EscalationInfo e) {
    final had = questions.any((q) => q.id == e.id);
    if (e.open) {
      if (!had) {
        questions = [e, ...questions];
        _newQuestions.add(e);
      }
    } else {
      questions = [for (final q in questions) if (q.id != e.id) q];
      if (e.state == EscalationState.answered || e.state == EscalationState.dismissed) onQuestionDecided(e.agent);
    }
    safeNotify();
  }

  /// Answer [id] with [text] (`null`: done); the error otherwise.
  Future<Object?> answerQuestion(String id, String text) => _decide(id, answer: text.trim());

  /// Set [id] aside without an answer.
  Future<Object?> dismissQuestion(String id) => _decide(id, dismiss: true);

  Future<Object?> _decide(String id, {String? answer, bool dismiss = false}) async {
    try {
      final e = await daemon.escalationAnswer(id, answer: answer, dismiss: dismiss);
      onEscalationEvent(e);
      return null;
    } on XClientException catch (e) {
      // Decided elsewhere meanwhile: the list follows the daemon
      unawaited(refreshQuestions());
      return e;
    }
  }

  /// Where [agent]'s questions go: [to] a contact, `null` the owner (the owner password).
  Future<Object?> setAgentEscalate(String agent, OwnerAuth auth, {String? to}) async {
    try {
      await ownerOp(auth, (d, pw) => d.agentEscalate(agent, pw, to: to));
      await refreshAgents();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// Re-read the agents (the model's).
  Future<void> refreshAgents();

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);

  void disposeQuestions() => unawaited(_newQuestions.close());
}
