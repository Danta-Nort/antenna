// SPDX-License-Identifier: AGPL-3.0-only
// The last step of Connect: what the owner does now, concretely, until the app calls Antenna for the first time.
// 1. An app that reads its MCP settings only when it starts (Claude Desktop, ChatGPT, Devin Desktop) has to be
//    started again. When it is open, "Restart <app> now" asks it to quit (its own Quit, which may save or ask first),
//    waits until it has closed and opens it again; when it is not open, "Open <app>". Nothing happens without the
//    click; the owner can also do it by hand. A CLI is simply started again; an app that picks up the change by itself
//    skips this step.
// 2. "In <app>, start a new chat and ask: Check my Antenna messages": the first tool call binds the agent's token.
// The status below turns from "Waiting" to "Connected" when the daemon reports the binding (the `agent` event).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../host/app_connect.dart' show AppQuitResult;
import '../../l10n/l10n.dart';
import '../../state/agent_status.dart';
import '../../state/ai_apps.dart';
import '../../state/ai_apps_model.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../widgets/x_buttons.dart';
import 'connect_widgets.dart';

/// Where the restart step stands.
enum _Restart {
  /// Asking whether the app runs.
  checking,
  running,
  notRunning,
  quitting,
  opening,
  restarted,
  opened,

  /// The owner restarts it by hand (their choice, or the window cannot tell whether it runs).
  byHand,
  notAllowed,
  stillRunning,
  openFailed,
}

class ConnectNextSteps extends StatefulWidget {
  const ConnectNextSteps({super.key, required this.app, required this.agent, this.viaLink = false});
  final AiAppDef app;

  /// The app's agent in the daemon (its status is shown live).
  final String agent;

  /// Connected through the app's own install link: the running app added the server itself, no restart.
  final bool viaLink;

  @override
  State<ConnectNextSteps> createState() => _ConnectNextStepsState();
}

class _ConnectNextStepsState extends State<ConnectNextSteps> {
  late final AppRestart _restart =
      widget.viaLink ? const AppRestart.live() : AppScope.read(context).restartOf(widget.app);
  _Restart _state = _Restart.checking;

  AiAppDef get app => widget.app;

  @override
  void initState() {
    super.initState();
    if (_restart.kind == AppRestartKind.bundle) unawaited(_check());
  }

  Future<void> _check() async {
    final running = await AppScope.read(context).aiAppRunning(_restart.appPath!);
    if (!mounted) return;
    setState(() => _state = switch (running) {
          true => _Restart.running,
          false => _Restart.notRunning,
          null => _Restart.byHand,
        });
  }

  /// "Restart `<app>` now": the owner's click is the consent; quit, wait for the exit, open.
  Future<void> _restartNow() async {
    final m = AppScope.read(context);
    final path = _restart.appPath!;
    setState(() => _state = _Restart.quitting);
    final quit = await m.quitAiApp(path);
    if (!mounted) return;
    if (quit != AppQuitResult.quit) {
      setState(() => _state = switch (quit) {
            AppQuitResult.notAllowed => _Restart.notAllowed,
            AppQuitResult.stillRunning => _Restart.stillRunning,
            _ => _Restart.byHand,
          });
      return;
    }
    await _open(restarted: true);
  }

  Future<void> _open({bool restarted = false}) async {
    setState(() => _state = _Restart.opening);
    final ok = await AppScope.read(context).openAiApp(_restart.appPath!);
    if (!mounted) return;
    setState(() => _state = ok ? (restarted ? _Restart.restarted : _Restart.opened) : _Restart.openFailed);
  }

  /// Step 2 waits until step 1 is settled: one action at a time.
  bool get _askReady => switch (_state) {
        _Restart.checking || _Restart.running || _Restart.notRunning || _Restart.quitting || _Restart.opening =>
          _restart.kind != AppRestartKind.bundle,
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final connected =
        AgentStatus.of(m.agents.where((a) => a.name == widget.agent).firstOrNull).state == AgentLinkState.connected;
    final steps = <Widget Function(int n)>[
      if (_restart.kind != AppRestartKind.live) (n) => _NumberedStep(n, done: connected || _restartDone, child: _first(l)),
      if (_askReady)
        (n) => _NumberedStep(
              n,
              key: const Key('connect-ask'),
              done: connected,
              child: _ask(l),
            ),
    ];
    return Container(
      key: const Key('connect-next'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XRadius.m),
        border: Border.all(color: XColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.connectNextTitle.toUpperCase(), style: XText.overline),
        const SizedBox(height: 8),
        for (var i = 0; i < steps.length; i++) steps[i](i + 1),
        ConnectLiveStatus(
          app: app,
          agent: widget.agent,
          waiting: l.connectWaitingFirstCall(app.name),
        ),
      ]),
    );
  }

  bool get _restartDone => switch (_restart.kind) {
        AppRestartKind.bundle => _state == _Restart.restarted || _state == _Restart.opened,
        _ => false,
      };

  Widget _first(AppLocalizations l) {
    final name = app.name;
    if (_restart.kind == AppRestartKind.cli) return _line(l.connectRestartCli(name));
    if (_restart.kind == AppRestartKind.byHand) return _line(l.connectRestartByHand(name));
    final skip = TextButton(
      key: const Key('connect-restart-skip'),
      onPressed: () => setState(() => _state = _Restart.byHand),
      child: Text(l.connectRestartSelf),
    );
    final open = OutlinedButton(
      key: const Key('connect-open-app'),
      style: XButtons.secondary(),
      onPressed: _open,
      child: Text(l.connectOpenApp(name)),
    );
    return switch (_state) {
      _Restart.checking => _busy(l.connectChecking(name)),
      _Restart.running => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line(l.connectRestartRunning(name)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton.icon(
              key: const Key('connect-restart'),
              style: XButtons.primary(),
              onPressed: _restartNow,
              icon: const Icon(Icons.restart_alt_rounded, size: 17),
              label: Text(l.connectRestartNow(name)),
            ),
            skip,
          ]),
          const SizedBox(height: 8),
          Text(l.connectRestartHow(name), style: XText.meta),
        ]),
      _Restart.notRunning => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line(l.connectNotRunning(name)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [open, skip]),
        ]),
      _Restart.quitting => _busy(l.connectQuitting(name)),
      _Restart.opening => _busy(l.connectOpening(name)),
      _Restart.restarted => _line(l.connectRestarted(name), key: const Key('connect-restarted')),
      _Restart.opened => _line(l.connectOpened(name), key: const Key('connect-opened')),
      _Restart.byHand => _line(l.connectRestartByHand(name)),
      _Restart.notAllowed => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line(l.connectQuitNotAllowed(name), warn: true),
          const SizedBox(height: 8),
          open,
        ]),
      _Restart.stillRunning => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line(l.connectQuitStillRunning(name), warn: true),
          const SizedBox(height: 8),
          open,
        ]),
      _Restart.openFailed => _line(l.connectOpenFailed(name), warn: true),
    };
  }

  Widget _ask(AppLocalizations l) {
    final prompt = l.connectAskPrompt;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _line(app.macApps.isEmpty ? l.connectAskCli(app.name) : l.connectAskChat(app.name)),
      const SizedBox(height: 4),
      Row(children: [
        Flexible(
          child: Text('“$prompt”', key: const Key('connect-ask-prompt'), style: XText.body.copyWith(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 4),
        CopyButton(prompt),
      ]),
    ]);
  }

  Widget _line(String text, {bool warn = false, Key? key}) =>
      Text(text, key: key, style: XText.body.copyWith(fontSize: 12, color: warn ? XColors.warn : null));

  Widget _busy(String text) => Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: XColors.accent)),
        const SizedBox(width: 8),
        Expanded(child: _line(text)),
      ]);
}

/// A numbered step; done steps show a check.
class _NumberedStep extends StatelessWidget {
  const _NumberedStep(this.n, {super.key, required this.done, required this.child});
  final int n;
  final bool done;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? XColors.ok.withValues(alpha: 0.15) : null,
              border: Border.all(color: done ? XColors.ok : XColors.accent),
            ),
            child: done
                ? Icon(Icons.check, size: 13, color: XColors.ok)
                : Text('$n', style: XText.monoSmall.copyWith(color: XColors.accent)),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ]),
      );
}
