// SPDX-License-Identifier: AGPL-3.0-only
// Agent wake (x-control/4, CONTROL §16): a rule "this contact writes → the daemon runs an agent in a sandbox".
// The daemon keeps the rules, the sandbox and the log; the window shows `wake_list`, `wake` events and the `wake` log
// entries.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/x_control.dart';
import 'owner_auth.dart';

/// The owner's own turn in a resident session, as this window asked it (PG-23, CONTROL §21 `wake_say`).
class ResidentTalk {
  ResidentTalk(this.text, {required this.toContact});

  /// What the owner wrote.
  final String text;

  /// The answer goes to the contact as the agent's reply.
  final bool toContact;

  /// The answer so far (`resident_delta`).
  String reply = '';

  /// What the agent is busy with right now (`tool:<name>`).
  String? activity;
  bool busy = true;

  /// The end of the turn.
  ResidentTurnReply? done;
  Object? error;
}

/// Ready-made commands (window presets). The daemon adds the required flags to `claude` itself (CONTROL §16).
enum WakePreset {
  claude('claude -p --output-format stream-json', 'CLAUDE_CODE_OAUTH_TOKEN'),
  codex('codex exec', 'OPENAI_API_KEY'),
  custom('', '');

  const WakePreset(this.command, this.secretName);
  final String command;

  /// Default secret name for this agent.
  final String secretName;
}

/// Split a command the way a shell would (quotes, `\`), without expansions and without running a shell, like
/// `antenna wake set --cmd`. `null` on an unclosed quote.
List<String>? splitCommand(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  var inWord = false;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < s.length && (s[i + 1] == '"' || s[i + 1] == r'\')) {
        cur.write(s[++i]);
      } else {
        cur.write(c);
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      inWord = true;
    } else if (c == r'\' && i + 1 < s.length) {
      cur.write(s[++i]);
      inWord = true;
    } else if (c == ' ' || c == '\t' || c == '\n') {
      if (inWord) {
        out.add(cur.toString());
        cur.clear();
        inWord = false;
      }
    } else {
      cur.write(c);
      inWord = true;
    }
  }
  if (quote != null) return null;
  if (inWord) out.add(cur.toString());
  return out;
}

mixin WakeMixin on ChangeNotifier {
  XDaemon get daemon;

  /// One owner command with the password or one touch ([TouchIdMixin.ownerOp], D-131).
  Future<T> ownerOp<T>(OwnerAuth auth, Future<T> Function(XDaemon d, String password) op);

  /// Notify the window (no error after dispose: daemon replies can arrive after the model is closed).
  void safeNotify();

  List<WakeRuleInfo> wakeRules = const [];

  /// This OS's sandbox: `bwrap` / `landlock` / `none` (empty if not asked yet or the daemon is older than v4).
  String wakeSandbox = '';
  String wakeSandboxDetail = '';

  /// The daemon supports wake (x-control/4).
  bool wakeSupported = true;

  /// The latest `wake` event per link (started, finished, refused).
  final Map<String, WakeEvent> lastWakeEvent = {};

  WakeRuleInfo? wakeRuleOf(String linkId) => wakeRules.where((r) => r.linkId == linkId).firstOrNull;

  void _apply(WakeReply r) {
    wakeRules = r.rules;
    wakeSandbox = r.sandbox;
    wakeSandboxDetail = r.sandboxDetail;
    wakeSupported = true;
  }

  Future<void> refreshWake() async {
    try {
      _apply(await daemon.wakeList());
    } on XControlException catch (e) {
      if (e.code == XErrorCode.unknownCommand || e.code == XErrorCode.badRequest) wakeSupported = false;
    } on XClientException {
      return;
    }
    safeNotify();
  }

  /// Turn on (or replace) a rule: [request] gets the password to send (`''` with one touch, D-131). Returns the
  /// daemon error or `null`.
  Future<Object?> setWake(OwnerAuth auth, WakeSetRequest Function(String password) request) async {
    try {
      _apply(await ownerOp(auth, (d, pw) => d.wakeSet(request(pw))));
      safeNotify();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  Future<Object?> wakeOff(String contact) async {
    try {
      _apply(await daemon.wakeOff(contact));
      safeNotify();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  /// The owner's turn in progress or just answered, per link (this window's own `wake_say`).
  final Map<String, ResidentTalk> residentTalks = {};

  /// Say [text] to [linkId]'s resident agent as the owner (PG-23): the answer streams into [residentTalks]. Returns
  /// the daemon's error or `null`.
  Future<Object?> sayResident(String linkId, String text, {bool toContact = false, bool interrupt = false}) async {
    final t = residentTalks[linkId] = ResidentTalk(text, toContact: toContact);
    safeNotify();
    final d = daemon.wakeSay(linkId, text, toContact: toContact, interrupt: interrupt);
    final sub = d.events.listen((e) {
      if (e is! ResidentDeltaEvent) return;
      t
        ..reply += e.delta
        ..activity = e.delta.isEmpty ? e.activity : null;
      safeNotify();
    });
    try {
      final r = await d.result;
      if (r is ResidentTurnReply) {
        t.done = r;
        if (r.text.isNotEmpty) t.reply = r.text;
      }
    } on XClientException catch (e) {
      t.error = e;
    }
    // Not awaited: a single-subscription cancel completes in the root zone, which a test's fake clock never runs.
    unawaited(sub.cancel());
    t
      ..busy = false
      ..activity = null;
    await refreshWake();
    return t.error;
  }

  /// `wake_session` for [linkId]'s resident agent: stop, compact, reset (with [password]). Returns the daemon's error
  /// or `null`.
  Future<Object?> residentSession(String linkId, ResidentAction action, {OwnerAuth? auth}) async {
    try {
      final r = auth == null
          ? await daemon.wakeSession(linkId, action)
          : await ownerOp(auth, (d, pw) => d.wakeSession(linkId, action, password: pw));
      wakeRules = [for (final x in wakeRules) x.linkId == linkId ? x.withResident(r.resident) : x];
      if (action == ResidentAction.reset) residentTalks.remove(linkId);
      safeNotify();
      return null;
    } on XClientException catch (e) {
      return e;
    }
  }

  void onWakeEvent(WakeEvent e) {
    lastWakeEvent[e.linkId] = e;
    // A resident session changed: its counters and state come with the rules
    if (wakeRuleOf(e.linkId)?.resident != null) unawaited(refreshWake());
  }

  void clearWake() {
    wakeRules = const [];
    lastWakeEvent.clear();
    residentTalks.clear();
  }
}
