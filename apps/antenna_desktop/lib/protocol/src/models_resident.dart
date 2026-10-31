// SPDX-License-Identifier: AGPL-3.0-only
// Resident agents (x-control/6, CONTROL §21, D-93; parked: v7, D-121): a part of models.dart. A resident rule keeps
// one agent process per contact with its context; the window shows the session's state and counters, the owner's own
// turns (`wake_say`) and the session commands (`wake_session`).

part of 'models.dart';

/// A resident session's state (`WakeRuleInfo.resident.state`).
abstract final class ResidentState {
  static const sleeping = 'sleeping';
  static const idle = 'idle';
  static const busy = 'busy';
  static const failed = 'failed';
}

/// A resident rule's session (`WakeRuleInfo.resident`).
final class ResidentInfo {
  const ResidentInfo({
    required this.state,
    this.sessionId,
    this.sessionStartedMs,
    this.turns = 0,
    this.ownerTurns = 0,
    this.queued = 0,
    this.starts = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.contextTokens = 0,
    this.costMicroUsd,
    this.lastTurnMs,
    this.compactions = 0,
    this.lastCompactMs,
    this.ceiling,
    this.idleStopSecs = 0,
    this.compactIdleSecs = 0,
    this.compactAboveTokens = 0,
    this.parked = false,
  });

  factory ResidentInfo.fromJson(Json j) => ResidentInfo(
        state: _optStr(j, 'state') ?? ResidentState.sleeping,
        sessionId: _optStr(j, 'session_id'),
        sessionStartedMs: _optInt(j, 'session_started_ms'),
        turns: _optInt(j, 'turns') ?? 0,
        ownerTurns: _optInt(j, 'owner_turns') ?? 0,
        queued: _optInt(j, 'queued') ?? 0,
        starts: _optInt(j, 'starts') ?? 0,
        inputTokens: _optInt(j, 'input_tokens') ?? 0,
        outputTokens: _optInt(j, 'output_tokens') ?? 0,
        cacheReadTokens: _optInt(j, 'cache_read_tokens') ?? 0,
        cacheWriteTokens: _optInt(j, 'cache_write_tokens') ?? 0,
        contextTokens: _optInt(j, 'context_tokens') ?? 0,
        costMicroUsd: _optInt(j, 'cost_micro_usd'),
        lastTurnMs: _optInt(j, 'last_turn_ms'),
        compactions: _optInt(j, 'compactions') ?? 0,
        lastCompactMs: _optInt(j, 'last_compact_ms'),
        ceiling: _optInt(j, 'ceiling'),
        idleStopSecs: _optInt(j, 'idle_stop_secs') ?? 0,
        compactIdleSecs: _optInt(j, 'compact_idle_secs') ?? 0,
        compactAboveTokens: _optInt(j, 'compact_above_tokens') ?? 0,
        parked: _bool(j, 'parked'),
      );

  /// [ResidentState]: `sleeping` (no process), `idle` (waits for a turn), `busy`, `failed` (three crashes).
  final String state;
  final String? sessionId;
  final int? sessionStartedMs;

  /// Turns of the session; [ownerTurns] of them the owner's own.
  final int turns;
  final int ownerTurns;

  /// Turns waiting behind the one in progress.
  final int queued;

  /// How many times the process started for this session.
  final int starts;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// The context of the last model call: what the next turn sends again.
  final int contextTokens;

  /// The agent CLI's own estimate at API prices, millionths of a dollar.
  final int? costMicroUsd;
  final int? lastTurnMs;
  final int compactions;
  final int? lastCompactMs;

  /// The session's taint (D-29): it stays until a reset.
  final int? ceiling;
  final int idleStopSecs;
  final int compactIdleSecs;
  final int compactAboveTokens;

  /// While it sleeps, the session's files are in the encrypted database (v7, D-121).
  final bool parked;

  bool get started => sessionId != null;
}

/// `resident_session`: reply to `wake_session`.
final class ResidentSessionReply extends Reply {
  const ResidentSessionReply({required this.contact, required this.resident});
  final String contact;
  final ResidentInfo resident;
}

/// `resident_turn`: the end of the owner's own turn (`wake_say`).
final class ResidentTurnReply extends Reply {
  const ResidentTurnReply({
    required this.contact,
    required this.turn,
    required this.outcome,
    this.text = '',
    this.detail = '',
    this.messageId,
  });

  factory ResidentTurnReply.fromJson(Json j) => ResidentTurnReply(
        contact: _str(j, 'contact'),
        turn: _optInt(j, 'turn') ?? 0,
        outcome: _str(j, 'outcome'),
        text: _optStr(j, 'text') ?? '',
        detail: _optStr(j, 'detail') ?? '',
        messageId: _optStr(j, 'message_id'),
      );

  final String contact;
  final int turn;

  /// `done`, `interrupted`, `failed`.
  final String outcome;

  /// The agent's answer to the owner (empty when it went to the contact).
  final String text;

  /// Why it was interrupted or failed, the daemon's English text.
  final String detail;

  /// With `to_contact`: the final message of the agent's reply to the contact.
  final String? messageId;
}

/// A piece of the agent's answer, only on the `wake_say` connection that asked. An empty [delta] is an [activity]
/// change (`tool:<name>`).
final class ResidentDeltaEvent extends XEvent {
  const ResidentDeltaEvent({required this.contact, required this.turn, required this.delta, this.activity});
  final String contact;
  final int turn;
  final String delta;
  final String? activity;
}
