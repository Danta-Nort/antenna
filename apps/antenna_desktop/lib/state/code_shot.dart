// SPDX-License-Identifier: AGPL-3.0-only
// "Screenshot" under a Code mode terminal (D-UI-27): the owner picks an area or a window with the system's tool, and
// the window hands the image to that agent, so the owner does not have to describe where on the screen something is.
//
// Claude Code attaches an image when its path arrives as a paste: a bracketed paste of the absolute path of a PNG
// becomes "[Image #1]" in its prompt (checked on Claude Code 2.1.289; a path typed key by key stays text, and a
// leading `/` even opens the command menu). The window pastes the path of the file it took itself
// (`AllowedLine.screenshot`), without Enter: the owner adds what to do and sends it. It pastes only on the owner's click
// and only when Claude Code waits at its prompt, by its hooks or by the screen check (code_wake.dart), never into a
// dialog; otherwise the screenshot waits for the prompt for [shotWait], then stays in its folder for the owner to use.
// Codex and own commands: the file is saved and its path shown to the owner; nothing is typed.
//
// On macOS the tool runs only when this build has Screen Recording (host/screen_permission.dart): without it macOS puts
// its own question over the tool and the picture holds only the desktop, so the window explains the fix first and runs
// nothing (D-UI-41).

import 'dart:async';

import '../host/screen_permission.dart';
import '../host/screenshot.dart';
import 'agent_launch.dart' show AgentCli;
import 'claude_state.dart';
import 'code_mode.dart';
import 'code_wake.dart';

/// What became of a screenshot.
enum ShotOutcome {
  /// Pasted into Claude Code's prompt.
  attached,

  /// Taken; waits for Claude Code's prompt.
  waiting,

  /// Taken and kept; the owner gets its path (Codex, an own command, a path that cannot be pasted, or the prompt did
  /// not come back in time).
  saved,

  /// The owner cancelled the capture.
  cancelled,

  /// The capture failed or its file was refused.
  failed,

  /// This build has no Screen Recording (macOS): the tool did not run; the window shows how to allow it.
  needsPermission,
}

final class ShotResult {
  const ShotResult(this.outcome, {this.shot, this.error});
  final ShotOutcome outcome;
  final WindowScreenshot? shot;
  final Object? error;
}

/// When a screenshot may be pasted into Claude Code: at its prompt by the hooks (a draft of the owner's is fine: the
/// paste adds to it and nothing is sent), or by the screen check when the hooks cannot tell. Never in a dialog.
bool canPasteShot(ClaudeTracker t, TerminalScreen screen) => switch (t.state) {
      ClaudeState.idle => screenGuard(screen),
      ClaudeState.unknown => claudeCodeReady(screen),
      _ => false,
    };

/// How long a screenshot waits for Claude Code's prompt.
const shotWait = Duration(minutes: 2);

/// The terminal stays silent this long before a waiting screenshot is pasted.
const shotQuiet = Duration(milliseconds: 600);

class _PendingShot {
  _PendingShot(this.shot, this.line);
  final WindowScreenshot shot;
  final AllowedLine line;
  Timer? check;
  Timer? expiry;

  void cancel() {
    check?.cancel();
    expiry?.cancel();
  }
}

mixin CodeShotMixin on CodeWakeMixin {
  final Map<int, _PendingShot> _shots = {};
  final Set<int> _capturing = {};

  /// The screenshots that did not reach the prompt, by run: shown with their path.
  final Map<int, WindowScreenshot> keptShots = {};

  /// This computer has a screenshot tool and a folder for screenshots.
  bool get screenshotsAvailable => agentHost?.shots != null && agentHost?.capture != null;

  /// Screen Recording for this build as last read (`null`: not read yet).
  ScreenPermission? screenPermission;

  /// A screenshot met a missing Screen Recording in this window session (the Check row is then a problem).
  bool screenPermissionBlocked = false;

  /// Read Screen Recording for this build (never prompts).
  Future<ScreenPermission> checkScreenPermission() async {
    final p = await (agentHost?.screenPermission ?? const NoScreenPermission()).check();
    if (p != screenPermission) {
      screenPermission = p;
      safeNotify();
    }
    return p;
  }

  /// The capture tool is open for [run].
  bool capturing(AgentRun run) => _capturing.contains(run.id);

  /// A screenshot waits for [run]'s prompt.
  WindowScreenshot? waitingShot(AgentRun run) => _shots[run.id]?.shot;

  /// "Screenshot": let the owner take one and hand it to [run]'s agent. [ask]: when Screen Recording is still missing,
  /// ask macOS (its own question, at most once per build) before giving up ("Try again" on the window's explanation).
  Future<ShotResult> takeScreenshot(AgentRun run, {bool ask = false}) async {
    final host = agentHost;
    final store = host?.shots;
    final tool = host?.capture;
    if (host == null || store == null || tool == null || !run.alive || !_capturing.add(run.id)) {
      return const ShotResult(ShotOutcome.failed);
    }
    safeNotify();
    final WindowScreenshot shot;
    try {
      var access = await checkScreenPermission();
      if (access == ScreenPermission.missing && ask) access = await host.screenPermission.request();
      screenPermission = access;
      if (access == ScreenPermission.missing) {
        screenPermissionBlocked = true;
        return const ShotResult(ShotOutcome.needsPermission);
      }
      if (!run.alive) return const ShotResult(ShotOutcome.failed);
      shot = await store.capture(run.spec.agent, tool, now: now());
    } on ScreenshotException catch (e) {
      return ShotResult(e.reason == ScreenshotFailure.cancelled ? ShotOutcome.cancelled : ShotOutcome.failed, error: e);
    } finally {
      _capturing.remove(run.id);
      safeNotify();
    }
    final line = AllowedLine.screenshot(shot);
    if (run.spec.cli != AgentCli.claude || line == null || !run.alive) return _keep(run, shot);
    _shots.remove(run.id)?.cancel();
    final p = _shots[run.id] = _PendingShot(shot, line);
    watchRun(run);
    if (_paste(run, p)) return ShotResult(ShotOutcome.attached, shot: shot);
    p.expiry = Timer(shotWait, () {
      if (identical(_shots[run.id], p)) {
        _shots.remove(run.id)?.cancel();
        _keep(run, shot);
      }
    });
    safeNotify();
    return ShotResult(ShotOutcome.waiting, shot: shot);
  }

  /// The owner gave up on the waiting screenshot: it stays in its folder, with its path shown.
  void cancelWaitingShot(AgentRun run) {
    final p = _shots.remove(run.id);
    if (p == null) return;
    p.cancel();
    _keep(run, p.shot);
  }

  void dismissKeptShot(AgentRun run) {
    if (keptShots.remove(run.id) != null) safeNotify();
  }

  ShotResult _keep(AgentRun run, WindowScreenshot shot) {
    keptShots[run.id] = shot;
    safeNotify();
    return ShotResult(ShotOutcome.saved, shot: shot);
  }

  /// Paste now if Claude Code waits at its prompt; `true` when pasted.
  bool _paste(AgentRun run, _PendingShot p) {
    if (!run.alive || !canPasteShot(run.claude, run.screen())) return false;
    if (!inputOf(run).type(p.line)) return false;
    _shots.remove(run.id)?.cancel();
    keptShots.remove(run.id);
    logCodeLine(CodeLineEntry(at: now(), agent: run.spec.agent, kind: CodeLineKind.screenshot));
    return true;
  }

  @override
  void runChanged(AgentRun run) {
    super.runChanged(run);
    final p = _shots[run.id];
    if (p == null) return;
    if (!run.alive) {
      cancelWaitingShot(run);
      return;
    }
    // Paste once the terminal has settled after the change.
    p.check?.cancel();
    final seen = run.activity;
    p.check = Timer(shotQuiet, () {
      if (identical(_shots[run.id], p) && run.activity == seen) _paste(run, p);
    });
  }

  void disposeCodeShots() {
    for (final p in _shots.values) {
      p.cancel();
    }
    _shots.clear();
  }
}
