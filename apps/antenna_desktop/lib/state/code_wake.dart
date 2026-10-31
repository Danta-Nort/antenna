// SPDX-License-Identifier: AGPL-3.0-only
// Code mode wake (D-UI-23, D-UI-25): an agent CLI in a window terminal reads Antenna only while its turn runs. When a
// message the agent reads arrives (D-91), the window gets ONE built-in line to Claude Code: if a turn is running, the
// turn's Stop hook continues with that line by itself (host/code_hooks.dart); if Claude Code waits at its prompt, the
// window types the line, then Enter. After the owner approves one of its requests, the line is "Approved — continue.".
// The quick-reply buttons under the terminal type the same kind of fixed lines on the owner's click. A team's lead that
// runs here gets the team's line when somebody else changed one of its tasks (teams.dart `teamEventWakesLead`).
//
// Security: everything the window itself puts into a terminal is an [AllowedLine], whose constructor is private: the
// fixed phrases below, the owner's own local label of a contact, sanitized ([sanitizeContactLabel]), and the path of a
// screenshot the window took itself (code_shot.dart). A contact can at most cause a wake; it never chooses or adds
// text: the message itself is never typed (the agent reads it over MCP, as data, D-88).
//
// When to type comes from Claude Code's own hooks (claude_state.dart): idle at the prompt (Stop), with no draft of the
// owner's, and the screen agreeing that no dialog is up ([screenGuard]). Where the hooks cannot tell (an older Claude
// Code, hooks off, or the owner's keys changed the state), the screen check is the fallback ([claudeCodeReady]): the
// empty prompt, recognised by where the cursor stands and by the placeholder being drawn faint, which a draft cannot
// fake. Neither can tell: nothing is typed, and the owner sees that the wake is unavailable.
//
// Codex (PG-21) gets the same: 0.160 and later report through hooks of the same kind (once the owner trusted them in
// Codex's "Hooks need review"), and its Stop hook continues a running turn; older ones, or untrusted hooks, only say
// that a turn completed (`notify`, which Codex also runs for its helper threads), so then the screen must show its
// empty composer ([codexReady]) before a line is typed, and nothing goes into a running turn.
//
// An urgent message (CONTROL §33, experimental: only the daemon's verdict `urgent`, the owner's own message from an own
// computer to this agent) does not wait for the turn to end: the window presses Esc once if a turn runs and nothing
// forbids it (code_input.dart), then types the urgent line at the prompt by the usual rules, past the 30 s line limit.
// Where Esc is not allowed (a dialog, the owner's draft, an interrupt less than 30 s ago) the urgent line waits like a
// wake, and a running turn may still take it through its Stop hook. What may be pressed or typed, and when, is decided
// in one place: [RunInput].

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../host/code_hooks.dart';
import '../protocol/x_control.dart';
import 'agent_launch.dart' show AgentCli;
import 'code_input.dart';
import 'code_lines.dart';
import 'code_mode.dart';
import 'code_screen.dart';

export 'code_input.dart';
export 'code_lines.dart';
export 'code_screen.dart';

/// Whether [agent] reads the incoming message [m] from [contact]: the daemon's rule (D-91, CONTROL §20), mirrored
/// only to decide a wake; the daemon still decides what the agent reads.
bool agentReads(AgentInfo agent, String contact, HistoryItem m) {
  if (m.outgoing || m.kind != 'text') return false;
  final links = agent.links;
  if (links != null && !links.contains(contact)) return false;
  return switch (m.to) {
    'agent' => m.toAgent == agent.name,
    'person' => false,
    // To everyone, or no address: only when the owner allows this agent messages to everyone. A daemon older than v6
    // has no such setting, and its agents read everything.
    _ => agent.everyone ?? true,
  };
}

/// An incoming message the daemon marked urgent for [agent] (CONTROL §33): addressed to that agent by name. The
/// daemon sets `urgent` only for such a message; this is defence in depth, not the rule.
bool urgentFor(AgentInfo agent, HistoryItem m) => m.urgent && !m.outgoing && m.to == 'agent' && m.toAgent == agent.name;

/// What the window typed into an agent's terminal, for the window's log. [urgent]: the urgent line, or the Esc that
/// interrupted the turn for it ([CodeLineEntry.interrupt]).
enum CodeLineKind { wake, approved, quick, screenshot, updated, answered, team, toAnswer, urgent }

final class CodeLineEntry {
  const CodeLineEntry(
      {required this.at,
      required this.agent,
      required this.kind,
      this.contact,
      this.reply,
      this.continued = false,
      this.version,
      this.team,
      this.interrupt = false,
      this.interruptedAt});
  final DateTime at;
  final String agent;
  final CodeLineKind kind;

  /// [CodeLineKind.wake], [CodeLineKind.urgent]: the contact named in the line (`null`: several, or not printable).
  final String? contact;

  /// [CodeLineKind.updated]: the version named in the line (sanitized).
  final String? version;

  /// [CodeLineKind.team]: the team named in the line (sanitized).
  final String? team;

  /// [CodeLineKind.quick]: which button.
  final QuickReply? reply;

  /// The turn's Stop hook continued with the line; nothing was typed.
  final bool continued;

  /// [CodeLineKind.urgent]: this entry is the Esc that interrupted the turn (nothing was typed yet).
  final bool interrupt;

  /// [CodeLineKind.urgent]: the urgent line came after the window interrupted the turn at this time.
  final DateTime? interruptedAt;
}

/// An urgent message waits for an agent (CONTROL §33), for the dock: who sent it (`null`: several computers), when the
/// window interrupted the turn for it (`null`: not yet), and otherwise why not ([InterruptBlock.idle]: no turn to
/// interrupt, the line only waits for the prompt).
final class UrgentWait {
  const UrgentWait({required this.block, this.contact, this.interruptedAt});
  final String? contact;
  final DateTime? interruptedAt;
  final InterruptBlock block;
}

/// One agent's automatic lines: what waits, the quiet check, the rate limit, a continuation left for the Stop hook.
class _Waker {
  _Waker(this.run, this.input);
  final AgentRun run;

  /// Everything the window presses or types into [run]'s terminal goes through this.
  final RunInput input;

  /// Contacts whose messages wait for a wake (labels as the daemon names the links).
  final Set<String> wakeFrom = {};
  bool approved = false;

  /// The owner answered or set aside one of the agent's questions (D-118).
  bool questionAnswered = false;

  /// A request waits for this approver's answer (CONTROL §31).
  bool toAnswer = false;

  /// The agent was restored after an automatic update to this version and has not been told yet (D-103).
  String? updatedTo;

  /// Teams this agent leads with news for it (somebody else changed a task).
  final Set<String> teams = {};

  /// Own computers whose urgent messages wait (CONTROL §33): their line covers every other waiting line but the team's.
  final Set<String> urgentFrom = {};

  /// Whether the urgent messages that wait interrupt the turn is decided once, when the first of them arrives: Esc
  /// then ([interruptedAt]), or never for them ([urgentBlock] says why; they wait like a wake).
  bool urgentDecided = false;
  InterruptBlock? urgentBlock;
  DateTime? interruptedAt;
  Timer? check;
  Timer? cooldown;

  /// The line left for the Stop hook (`null`: none).
  AllowedLine? offered;
  CodeLineEntry? offeredEntry;

  bool get pending =>
      urgent ||
      wakeFrom.isNotEmpty ||
      approved ||
      questionAnswered ||
      toAnswer ||
      updatedTo != null ||
      teams.isNotEmpty;

  /// An urgent line waits: it does not wait for the line limit.
  bool get urgent => urgentFrom.isNotEmpty;

  /// What a delivered line of [kind] answered: a team's line answers only the team's news; the others answer the inbox
  /// (and an approval, whose outcome is in the inbox, D-100; and the owner's answers to the agent's questions, D-118),
  /// and keep the team's news for the next line.
  void answered(CodeLineKind kind) {
    if (kind == CodeLineKind.team) {
      teams.clear();
      return;
    }
    // Only the urgent line answers urgent messages (a wake line the Stop hook took meanwhile does not).
    if (kind == CodeLineKind.urgent) _urgentDone();
    wakeFrom.clear();
    approved = false;
    questionAnswered = false;
    toAnswer = false;
    updatedTo = null;
  }

  void _urgentDone() {
    urgentFrom.clear();
    urgentDecided = false;
    urgentBlock = null;
    interruptedAt = null;
  }

  void clear() {
    _urgentDone();
    wakeFrom.clear();
    approved = false;
    questionAnswered = false;
    toAnswer = false;
    updatedTo = null;
    teams.clear();
    check?.cancel();
    check = null;
    if (offered != null) run.hooks?.withdrawContinue();
    offered = null;
    offeredEntry = null;
  }

  void dispose() {
    clear();
    cooldown?.cancel();
    cooldown = null;
    run.onActivity = null;
  }
}

/// Wake, the "Approved — continue." line and quick replies for agents running in Code mode.
mixin CodeWakeMixin on CodeMixin {
  /// The terminal must be silent this long before an automatic line is typed (it has just redrawn its prompt; Claude
  /// Code animates its spinner and timer while a turn runs).
  Duration get wakeQuiet => const Duration(seconds: 5);

  /// At most one automatic line per agent in this time; what comes meanwhile is coalesced into the next.
  Duration get wakeEvery => const Duration(seconds: 30);

  /// Agents the owner turned automatic lines off for ("Wake on new messages", on by default).
  final Set<String> codeWakeOff = {};

  /// Persists [codeWakeOff] (the window settings file).
  void Function(Set<String> off)? onCodeWakeChanged;

  /// What the window typed into terminals, newest last (the window's log; at most [_logSize]).
  final List<CodeLineEntry> codeLineLog = [];
  static const _logSize = 200;

  final Map<int, _Waker> _wakers = {};
  final Set<String> _approvalsTyped = {};

  /// Requests an approver here was told about (`<device>/<id>`): each wakes it once.
  final Set<String> _toAnswerSeen = {};

  /// Urgent messages already counted (by ID): each may interrupt once.
  final Set<String> _urgentSeen = {};

  bool codeWakeOn(String agent) => !codeWakeOff.contains(agent);

  void setCodeWake(String agent, bool on) {
    if (on ? codeWakeOff.remove(agent) : codeWakeOff.add(agent)) {
      if (!on) {
        for (final w in _wakers.values) {
          if (w.run.spec.agent == agent) w.clear();
        }
      }
      onCodeWakeChanged?.call({...codeWakeOff});
      safeNotify();
    }
  }

  /// A wake or "Approved" line waits for [run] (to go idle, or for its turn's end).
  bool codeLinePending(AgentRun run) => _wakers[run.id]?.pending ?? false;

  /// A line waits, but neither Claude Code's hooks nor its screen say when it may be typed: its hooks have not
  /// reported since it started (an older version, or hooks turned off, [AgentRun.hooksLate]) and the screen shows no
  /// layout the checks know. Nothing is typed; the dock says so.
  bool codeWakeUnavailable(AgentRun run) =>
      codeLinePending(run) &&
      run.hooksLate(now()) &&
      !(run.spec.cli == AgentCli.codex ? codexLayoutKnown(run.screen()) : claudeLayoutKnown(run.screen()));

  /// The last line the window gave [agent] by itself.
  CodeLineEntry? lastCodeLine(String agent) {
    for (final e in codeLineLog.reversed) {
      if (e.agent == agent && e.kind != CodeLineKind.quick && e.kind != CodeLineKind.screenshot) return e;
    }
    return null;
  }

  /// A new incoming message (the subscription's `message` event, not a re-read of history): wake every Claude Code or
  /// Codex agent running here that reads it. Own commands get no automatic lines (their prompt is unknown).
  void onCodeMessage(String contact, HistoryItem m) {
    if (m.outgoing || m.isReceipt) return;
    for (final run in liveRuns) {
      final name = run.spec.agent;
      if (!run.spec.cli.wakes || !codeWakeOn(name) || isWakeAgent(name)) continue;
      // An agent the window does not know yet: no wake (could not check = no).
      final info = agents.where((a) => a.name == name).firstOrNull;
      if (info == null || !agentReads(info, contact, m)) continue;
      final w = _waker(run);
      if (urgentFor(info, m)) {
        if (!_seenUrgent(m.id)) w.urgentFrom.add(contact);
      } else {
        w.wakeFrom.add(contact);
      }
      _step(run);
    }
  }

  /// A `message_fact` of [run]'s agent from `agent_watch` (no owner session, CONTROL §23): the daemon sends only the
  /// messages the agent itself may read, so the fact is the visibility rule's answer. [contact] is the owner's label.
  /// [urgent] is the daemon's verdict (CONTROL §33); it counts once per message [id], and not at all without one.
  void onCodeFact(AgentRun run, String contact, {String id = '', bool urgent = false}) {
    final name = run.spec.agent;
    if (!run.alive || !run.spec.cli.wakes || !codeWakeOn(name) || isWakeAgent(name)) return;
    final w = _waker(run);
    if (urgent && id.isNotEmpty) {
      if (!_seenUrgent(id)) w.urgentFrom.add(contact);
    } else {
      w.wakeFrom.add(contact);
    }
    _step(run);
  }

  /// [id] was counted before; otherwise it is counted now.
  bool _seenUrgent(String id) {
    if (!_urgentSeen.add(id)) return true;
    if (_urgentSeen.length > 512) _urgentSeen.remove(_urgentSeen.first);
    return false;
  }

  /// What the dock says about an urgent message for [run] (`null`: none waits).
  UrgentWait? urgentWait(AgentRun run) {
    final w = _wakers[run.id];
    if (w == null || !w.urgent) return null;
    final one = w.urgentFrom.length == 1 ? sanitizeContactLabel(w.urgentFrom.first) : '';
    return UrgentWait(
      contact: one.isEmpty ? null : one,
      interruptedAt: w.interruptedAt,
      block: w.urgentBlock ?? InterruptBlock.idle,
    );
  }

  /// What the window may put into [run]'s terminal, and when (code_input.dart).
  @protected
  RunInput inputOf(AgentRun run) => _waker(run).input;

  /// [run] was restored after an automatic update to [version] (code_restore.dart): tell it once, by the same rules
  /// as a wake (its Stop hook if a turn runs, otherwise typed at the idle prompt). Claude Code only, and only while
  /// "Wake on new messages" is on for the agent: the switch covers every line the window gives by itself.
  void queueUpdateLine(AgentRun run, String version) {
    if (!run.alive || !run.spec.cli.wakes || !codeWakeOn(run.spec.agent)) return;
    _waker(run).updatedTo = version;
    _step(run);
  }

  /// [lead] leads [team], and somebody else changed one of its tasks (teams.dart): the team's line, by the same rules
  /// as a wake. Claude Code only, and only while "Wake on new messages" is on for the agent.
  void onTeamLeadNews(String lead, String team) {
    final run = runOf(lead);
    if (run == null || !run.alive || run.spec.cli != AgentCli.claude || !codeWakeOn(lead) || isWakeAgent(lead)) return;
    _waker(run).teams.add(team);
    _step(run);
  }

  /// The team's line still waits for [run].
  bool teamLinePending(AgentRun run) => _wakers[run.id]?.teams.isNotEmpty ?? false;

  /// The update line still waits for [run].
  bool updateLinePending(AgentRun run) => _wakers[run.id]?.updatedTo != null;

  /// The owner approved [a] (the reply, a batch item or the subscription event; each request counts once).
  void onCodeApproved(ApprovalInfo a) {
    if (!a.byAgent || a.state != 'approved' || !_approvalsTyped.add(a.id)) return;
    if (_approvalsTyped.length > 512) _approvalsTyped.remove(_approvalsTyped.first);
    final run = runOf(a.requester);
    if (run == null || !run.alive || !run.spec.cli.wakes || !codeWakeOn(run.spec.agent)) return;
    _waker(run).approved = true;
    _step(run);
  }

  /// The owner answered or set aside a question of [agent] (D-118): one line, by the same rules as a wake.
  void onCodeAnswered(String agent) {
    final run = runOf(agent);
    if (run == null || !run.alive || !run.spec.cli.wakes || !codeWakeOn(agent)) return;
    _waker(run).questionAnswered = true;
    _step(run);
  }

  /// A request waits for [run]'s agent as an approver (CONTROL §31): the `approval_to_answer` fact of its own watch
  /// ([key] names the request and its computer). One line per request, by the same rules as a wake; a message's wake
  /// line covers it.
  void onCodeToAnswerRun(AgentRun run, String key) {
    final name = run.spec.agent;
    if (!run.alive || !run.spec.cli.wakes || !codeWakeOn(name) || isWakeAgent(name)) return;
    if (!_toAnswerSeen.add(key)) return;
    if (_toAnswerSeen.length > 512) _toAnswerSeen.remove(_toAnswerSeen.first);
    _waker(run).toAnswer = true;
    _step(run);
  }

  /// The same for the agent named [agent], if it runs here.
  void onCodeToAnswer(String agent, String key) {
    final run = runOf(agent);
    if (run != null) onCodeToAnswerRun(run, key);
  }

  /// A new request of this computer, seen by the owner's subscription: the approvers of this computer that may answer
  /// it now (`answerable_by` without a computer) get the line, as their own watch would give them.
  void onCodeToAnswerLocal(ApprovalInfo a) {
    for (final label in a.answerableBy) {
      if (!label.contains('@')) onCodeToAnswer(label, '/${a.id}');
    }
  }

  /// The owner clicked a quick reply under [run]'s terminal.
  void quickReply(AgentRun run, QuickReply q) {
    if (!run.alive) return;
    final line = q.line;
    if (line == null) {
      run.interrupt();
    } else {
      inputOf(run).type(line);
      // The owner just said it: what waited is answered.
      final w = _wakers[run.id];
      // "Check the chat" says what the update line would: read the inbox (an urgent message's too).
      if (q == QuickReply.checkChat) {
        w?._urgentDone();
        w?.wakeFrom.clear();
        w?.updatedTo = null;
        w?.questionAnswered = false;
      }
      if (q == QuickReply.approved) w?.approved = false;
      if (w != null && !w.pending && w.offered != null) {
        run.hooks?.withdrawContinue();
        w.offered = null;
        w.offeredEntry = null;
      }
    }
    logCodeLine(CodeLineEntry(at: now(), agent: run.spec.agent, kind: CodeLineKind.quick, reply: q));
  }

  void disposeCodeWake() {
    for (final w in _wakers.values) {
      w.dispose();
    }
    _wakers.clear();
  }

  _Waker _waker(AgentRun run) => _wakers.putIfAbsent(run.id, () {
        final w = _Waker(run, RunInput(run, now: now));
        // The screen changed, the owner pressed a key or a hook reported while something waits: look again.
        run.onActivity = () => runChanged(run);
        run.onHookEvent = (e) => _hook(run, e);
        return w;
      });

  /// Follow [run]'s output, keys and hooks from now on (a screenshot waits for its prompt, code_shot.dart).
  @protected
  void watchRun(AgentRun run) => _waker(run);

  /// Something changed in [run]'s terminal (output, the owner's keys, a hook): look again at what waits.
  @protected
  void runChanged(AgentRun run) => _step(run);

  /// The line that waits, and its log entry. The inbox also carries the outcome of approved requests (D-100), so a
  /// wake covers a waiting "Approved"; the update line asks the agent to read its inbox too, so it covers both.
  (AllowedLine, CodeLineEntry) _line(_Waker w, {required bool continued}) {
    // An urgent message first: its line asks the agent to read its inbox now, which covers every line below but the
    // team's.
    if (w.urgent) {
      final one = w.urgentFrom.length == 1 ? w.urgentFrom.first : null;
      final line = one == null ? AllowedLine.urgentAny : AllowedLine.urgentFrom(one);
      return (
        line,
        CodeLineEntry(
            at: now(),
            agent: w.run.spec.agent,
            kind: CodeLineKind.urgent,
            contact: identical(line, AllowedLine.urgentAny) ? null : sanitizeContactLabel(one!),
            continued: continued,
            interruptedAt: w.interruptedAt)
      );
    }
    if (w.updatedTo case final v?) {
      return (
        AllowedLine.updated(v),
        CodeLineEntry(
            at: now(),
            agent: w.run.spec.agent,
            kind: CodeLineKind.updated,
            version: sanitizeVersion(v),
            continued: continued)
      );
    }
    if (w.wakeFrom.isNotEmpty) {
      final one = w.wakeFrom.length == 1 ? w.wakeFrom.first : null;
      final line = one == null ? AllowedLine.wakeAny : AllowedLine.wakeFrom(one);
      return (
        line,
        CodeLineEntry(
            at: now(),
            agent: w.run.spec.agent,
            kind: CodeLineKind.wake,
            contact: identical(line, AllowedLine.wakeAny) ? null : sanitizeContactLabel(one!),
            continued: continued)
      );
    }
    // The answer is in the inbox, and so are decided approvals: the answered line covers both.
    if (w.questionAnswered) {
      return (
        AllowedLine.answered,
        CodeLineEntry(at: now(), agent: w.run.spec.agent, kind: CodeLineKind.answered, continued: continued)
      );
    }
    // An approver's request to answer (CONTROL §31); its own decided requests come in the same inbox.
    if (w.toAnswer) {
      return (
        AllowedLine.toAnswer,
        CodeLineEntry(at: now(), agent: w.run.spec.agent, kind: CodeLineKind.toAnswer, continued: continued)
      );
    }
    if (w.teams.isNotEmpty && !w.approved) {
      final one = w.teams.length == 1 ? w.teams.first : '';
      return (
        AllowedLine.teamTasks(one),
        CodeLineEntry(
            at: now(),
            agent: w.run.spec.agent,
            kind: CodeLineKind.team,
            team: one.isEmpty ? null : sanitizeContactLabel(one),
            continued: continued)
      );
    }
    return (
      AllowedLine.approved,
      CodeLineEntry(at: now(), agent: w.run.spec.agent, kind: CodeLineKind.approved, continued: continued)
    );
  }

  /// A hook event of [run]'s Claude Code.
  void _hook(AgentRun run, ClaudeHookEvent e) {
    final w = _wakers[run.id];
    if (w == null) return;
    if (e == ClaudeHookEvent.continued && w.offeredEntry != null) {
      // The Stop hook used the line: that is the wake.
      final entry = w.offeredEntry!;
      w
        ..offered = null
        ..offeredEntry = null
        ..answered(entry.kind);
      w.check?.cancel();
      w.check = null;
      _cool(run, w);
      logCodeLine(entry);
      return;
    }
    runChanged(run);
  }

  /// Decide what to do with what waits for [run]: leave it for the running turn's Stop hook, or check for quiet and
  /// type it, or wait for the next change.
  void _step(AgentRun run) {
    final w = _wakers[run.id];
    // An urgent line does not wait for the line limit.
    if (w == null || !w.pending || (w.cooldown != null && !w.urgent)) return;
    if (!run.alive || !codeWakeOn(run.spec.agent)) {
      w.clear();
      safeNotify();
      return;
    }
    if (w.urgent && !w.urgentDecided) _interrupt(run, w);
    final route = w.input.route();
    if (route == LineRoute.continueTurn && run.hooks != null) {
      final (line, entry) = _line(w, continued: true);
      if (w.offered?.text != line.text && run.hooks!.offerContinue(line.stopContinuation)) {
        w.offered = line;
        w.offeredEntry = entry;
        debugPrint('antenna/code: left a ${entry.kind.name} line for the Stop hook of "${run.spec.agent}"');
        safeNotify();
      }
      return;
    }
    if (w.check != null) return;
    final seen = run.activity;
    w.check = Timer(wakeQuiet, () {
      w.check = null;
      _deliver(run, w, seen);
    });
  }

  void _deliver(AgentRun run, _Waker w, int seen) {
    if (!run.alive || !codeWakeOn(run.spec.agent)) {
      w.clear();
      safeNotify();
      return;
    }
    if (!w.pending || (w.cooldown != null && !w.urgent)) return;
    // Output or keys since the check began: not settled yet (the next one restarts the check too).
    if (run.activity != seen) {
      _step(run);
      return;
    }
    // Not at an empty prompt now (a dialog, a draft, a turn, another program): wait for the next change.
    if (w.input.route() != LineRoute.type) {
      safeNotify();
      return;
    }
    // A line left for the Stop hook is taken back first; if the hook already took it, the turn goes on by itself.
    if (w.offered != null) {
      if (!(run.hooks?.withdrawContinue() ?? false)) return;
      w.offered = null;
      w.offeredEntry = null;
    }
    final (line, entry) = _line(w, continued: false);
    w.answered(entry.kind);
    w.input.type(line);
    logCodeLine(entry);
    _cool(run, w);
    safeNotify();
  }

  /// The first urgent message of a batch arrived for [run]: interrupt its turn now, once, if [RunInput.interruptBlock]
  /// allows it. If not (no turn runs; a dialog is open; the owner has a draft, so somebody is at this keyboard; an
  /// interrupt less than 30 s ago), the batch never interrupts: its line waits like a wake, for the prompt or the
  /// running turn's Stop hook, and the dock says why.
  void _interrupt(AgentRun run, _Waker w) {
    w.urgentDecided = true;
    final block = w.urgentBlock = w.input.interruptBlock();
    if (block != InterruptBlock.none || !w.input.interrupt()) {
      safeNotify();
      return;
    }
    w.interruptedAt = now();
    // No Stop hook follows an interrupt (Claude Code; Codex reports Interrupt): a line left for it is taken back, and
    // the urgent line is typed at the prompt.
    if (w.offered != null) {
      run.hooks?.withdrawContinue();
      w.offered = null;
      w.offeredEntry = null;
    }
    final one = w.urgentFrom.length == 1 ? sanitizeContactLabel(w.urgentFrom.first) : '';
    logCodeLine(CodeLineEntry(
        at: w.interruptedAt!,
        agent: run.spec.agent,
        kind: CodeLineKind.urgent,
        contact: one.isEmpty ? null : one,
        interrupt: true));
  }

  void _cool(AgentRun run, _Waker w) {
    w.cooldown?.cancel();
    w.cooldown = Timer(wakeEvery, () {
      w.cooldown = null;
      _step(run);
    });
  }

  void logCodeLine(CodeLineEntry e) {
    codeLineLog.add(e);
    if (codeLineLog.length > _logSize) codeLineLog.removeAt(0);
    // The window's log: who, why and when; never a message's text (the line itself is one of the fixed phrases).
    final what = e.interrupt ? 'interrupted the turn for' : (e.continued ? 'continued with' : 'typed');
    debugPrint('antenna/code: $what ${e.kind.name}'
        '${e.reply == null ? '' : ' ${e.reply!.name}'} into "${e.agent}"'
        '${e.contact == null ? '' : ' (from "${e.contact}")'}${e.version == null ? '' : ' (version ${e.version})'}'
        '${e.team == null ? '' : ' (team "${e.team}")'}'
        ' at ${e.at.toIso8601String()}');
    safeNotify();
  }
}
