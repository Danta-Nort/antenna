// SPDX-License-Identifier: AGPL-3.0-only
// "Live" bubbles of streaming messages (x-control/4, CONTROL §15). Chunks are ephemeral: only the final message, an
// ordinary `message_id` message, goes into the history. The window keeps a bubble per `stream_id` until the final
// message arrives and checks the text against `seq`/`text_len` (on a gap, it reloads `streams`).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'threads.dart';

/// Bubble state.
enum LiveStreamState {
  /// Being written: cursor, "typing…".
  streaming,

  /// Cut off with no final message for now (`reason`); the final message may still arrive (after approval, after the
  /// connection recovers).
  interrupted,

  /// The final message is already in the history, but the `message_id` message has not reached the window yet; the
  /// bubble is kept until it does.
  awaitingMessage,
}

class LiveStream {
  LiveStream({
    required this.streamId,
    required this.linkId,
    required this.contact,
    required this.outgoing,
    required this.startedAt,
  });

  final String streamId;
  final String linkId;
  final String contact;

  /// Which agent writes (PG-20): the contact's agent as its node names it, or my own agent; `null`: a person, or a
  /// node that does not say.
  String? viaAgent;

  /// `out`: this node is writing (the owner via the CLI, or their agent on wake).
  final bool outgoing;
  final DateTime startedAt;

  String text = '';
  int seq = -1;
  String? activity;

  /// `out`: the contact sees the stream as it is written (otherwise only the final message).
  bool live = true;
  LiveStreamState state = LiveStreamState.streaming;

  /// `interrupted`: the reason.
  String? reason;

  /// `final`: ID of the final message.
  String? messageId;

  /// The final message came with `end: interrupted`.
  bool endedInterrupted = false;

  /// A secret in an outgoing stream: the final message awaits owner approval (the approval request arrives as an
  /// `approval` event).
  bool get awaitingApproval => outgoing && state == LiveStreamState.interrupted && reason == 'cut';

  int get byteLength => utf8.encode(text).length;
}

mixin StreamsMixin on ChangeNotifier {
  XDaemon get daemon;

  /// Notify the window (no error after dispose: daemon replies can arrive after the model is closed).
  void safeNotify();

  /// Streams in progress (stream_id → bubble).
  final Map<String, LiveStream> liveStreams = {};

  /// Final messages that came with `end: interrupted` (message_id), marked "interrupted" in the chat.
  final Set<String> interruptedFinals = {};

  bool _resyncing = false;

  DateTime streamNow() => DateTime.now();

  /// Whether the link's chat has a message with this ID (the bubble of the final message).
  bool hasMessage(String linkId, String messageId);

  /// The link's bubbles ordered by start time. With [thread] (chats per agent, D-UI-32): a contact's agent that is
  /// named writes in its own chat only; an unnamed incoming stream (a person, or a node that does not say) and my
  /// own streams show in every chat, as before.
  List<LiveStream> streamsOf(String linkId, {ThreadKey? thread}) => liveStreams.values
      .where((s) =>
          s.linkId == linkId &&
          (thread == null || s.outgoing || s.viaAgent == null || thread == ThreadKey.agent(s.viaAgent!)))
      .toList()
    ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  void onStreamEvent(MessageStreamEvent e) {
    var s = liveStreams[e.streamId];
    if (s == null) {
      if (e.state == 'final') {
        // The final message of a stream the window never saw (the window started mid-stream): no bubble needed.
        if (e.end == 'interrupted' && e.messageId != null) interruptedFinals.add(e.messageId!);
        return;
      }
      s = LiveStream(
        streamId: e.streamId,
        linkId: e.linkId,
        contact: e.contact,
        outgoing: e.direction == 'out',
        startedAt: streamNow(),
      );
      liveStreams[e.streamId] = s;
    }
    if (e.viaAgent != null) s.viaAgent = e.viaAgent;
    final gap = s.seq >= 0 && e.seq != s.seq + 1;
    s.seq = e.seq;
    s.live = e.live;
    switch (e.state) {
      case 'streaming':
        s
          ..state = LiveStreamState.streaming
          ..reason = null
          ..activity = e.activity;
        if (gap) {
          unawaited(resyncStreams());
        } else {
          s.text += e.delta ?? '';
          // Nothing lost? Otherwise fetch the whole text from `streams`.
          if (s.byteLength != e.textLen) unawaited(resyncStreams());
        }
      case 'interrupted':
        s
          ..state = LiveStreamState.interrupted
          ..reason = e.reason
          ..activity = null;
        if (e.text != null) s.text = e.text!;
      case 'final':
        s
          ..messageId = e.messageId
          ..endedInterrupted = e.end == 'interrupted'
          ..activity = null;
        if (s.endedInterrupted && e.messageId != null) interruptedFinals.add(e.messageId!);
        if (e.messageId != null && hasMessage(s.linkId, e.messageId!)) {
          liveStreams.remove(s.streamId);
        } else {
          s.state = LiveStreamState.awaitingMessage;
        }
    }
  }

  /// A history message arrived: the bubble that was waiting for this final message is no longer needed.
  void onMessageArrived(String messageId) {
    liveStreams.removeWhere((_, s) => s.messageId == messageId);
  }

  /// Our own outgoing message: the final message of a stream that was waiting for approval (a secret). After
  /// `approve`, the sender's daemon sends the final message itself but sends its own window no `final` event with this
  /// `stream_id` (a deferred final message carries no stream ID), so the final message is recognized by its text: it
  /// starts with what the bubble held.
  void onOutgoingMessage(String linkId, HistoryItem m) {
    if (!m.outgoing) return;
    liveStreams.removeWhere((_, s) {
      if (s.linkId != linkId || !s.awaitingApproval) return false;
      final held = s.text.trimRight();
      return held.isNotEmpty && m.text.startsWith(held);
    });
  }

  /// Reload the streams in progress (a `seq` gap, `lagged`, the window starting mid-stream).
  Future<void> resyncStreams() async {
    if (_resyncing) return;
    _resyncing = true;
    try {
      final views = await daemon.streams();
      final seen = <String>{};
      for (final v in views) {
        seen.add(v.streamId);
        final s = liveStreams.putIfAbsent(
          v.streamId,
          () => LiveStream(
            streamId: v.streamId,
            linkId: v.linkId,
            contact: v.contact,
            outgoing: v.direction == 'out',
            startedAt: v.startedMs > 0 ? DateTime.fromMillisecondsSinceEpoch(v.startedMs) : streamNow(),
          ),
        );
        if (v.viaAgent != null) s.viaAgent = v.viaAgent;
        if (s.state == LiveStreamState.streaming) {
          s
            ..text = v.text
            ..seq = v.seq
            ..activity = v.activity
            ..live = v.live;
        }
      }
      // Streams that were running but are gone from the daemon ended while the window was not listening: wait for the
      // final message from the history.
      for (final s in liveStreams.values) {
        if (!seen.contains(s.streamId) && s.state == LiveStreamState.streaming) s.state = LiveStreamState.interrupted;
      }
    } on XControlException catch (e) {
      // A daemon older than x-control/4 has no streams.
      if (e.code != XErrorCode.unknownCommand && e.code != XErrorCode.badRequest) debugPrint('streams: $e');
    } on XClientException {
      // The reconnect will sort it out.
    } finally {
      _resyncing = false;
    }
    safeNotify();
  }

  void clearStreams() {
    liveStreams.clear();
    interruptedFinals.clear();
  }
}
