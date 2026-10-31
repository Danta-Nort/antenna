// SPDX-License-Identifier: AGPL-3.0-only
// The screen before sign-in: daemon not answering / new node (init) / keys locked (unlock). The password goes to the
// daemon over the control socket (0600, same uid); the UI does not store it. With Touch ID on (D-102), "Unlock with
// Touch ID" / "Sign in with Touch ID" stands above the password field, which always stays. When the app opens, the
// first gate shows the Touch ID sheet by itself, once (D-131); after that, and after "Lock keys", only on a click.
// Any failure puts the cursor in the password field, saying why when there is a reason.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../host/daemon_host.dart';
import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/app_model.dart';
import '../../state/code_wake.dart' show sanitizeVersion;
import '../../state/messages.dart';
import '../../state/touch_id.dart';
import '../../theme/antenna_mark.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../security/touch_id_text.dart';
import '../settings/check_panel.dart';
import '../widgets/dialog_shell.dart';

class GateScreen extends StatelessWidget {
  const GateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    return Scaffold(
      body: Stack(children: [
        const Positioned.fill(child: _Backdrop()),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(XSpace.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const _Brand(),
                const SizedBox(height: 28),
                AnimatedSwitcher(
                  duration: XMotion.normal,
                  child: switch (m.phase) {
                    _ when m.notOwner => const _NotOwner(key: ValueKey('not-owner')),
                    _ when m.startingDaemon => const _Connecting(key: ValueKey('starting')),
                    Phase.connecting => const _Connecting(key: ValueKey('connecting')),
                    Phase.unreachable => const _Unreachable(key: ValueKey('unreachable')),
                    Phase.uninitialized => const _PasswordCard(key: ValueKey('init'), mode: _PwMode.create),
                    Phase.locked || Phase.unlocked => const _PasswordCard(key: ValueKey('unlock'), mode: _PwMode.unlock),
                    Phase.loginRequired => const _PasswordCard(key: ValueKey('login'), mode: _PwMode.login),
                  },
                ),
                // Any error state: the checks and their fixes in one place.
                if (!m.notOwner &&
                    !m.startingDaemon &&
                    (m.phase == Phase.unreachable || m.phase == Phase.locked || m.phase == Phase.loginRequired)) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('gate-check'),
                    onPressed: () => showCheckDialog(context),
                    icon: const Icon(Icons.fact_check_outlined, size: 16),
                    label: Text(context.l.gateCheck),
                  ),
                ],
                const SizedBox(height: 16),
                _Footer(m),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Background of the sign-in screen: plain light (or deep blue) with a soft spot of the brand color.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: XColors.bg0,
          gradient: RadialGradient(
            center: const Alignment(0.85, -1.1),
            radius: 1.25,
            colors: [Color.alphaBlend(XColors.brand.withValues(alpha: XColors.isDark ? 0.14 : 0.08), XColors.bg0), XColors.bg0],
          ),
        ),
      );
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => Column(children: [
        const AntennaAppIcon(size: 64),
        const SizedBox(height: 16),
        Text('Antenna', style: XText.h1.copyWith(fontSize: 28)),
        const SizedBox(height: 8),
        Text(context.l.gateTagline, style: XText.body.copyWith(color: XColors.textDim)),
      ]);
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
        decoration: xPanel(fill: XColors.bg1, border: XColors.line, radius: XRadius.xl, glow: 1),
        child: child,
      );
}

class _Connecting extends StatelessWidget {
  const _Connecting({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final h = m.host;
    final l = context.l;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: XColors.accent),
          ),
          const SizedBox(width: 16),
          Text(m.startingDaemon ? l.gateStartingDaemon : l.gateConnecting, style: XText.body),
        ]),
        if (m.startingDaemon && h != null) ...[
          const SizedBox(height: 12),
          Text(
            h.outlivesWindow ? l.gateDaemonOutlivesWindow : l.gateDaemonWithWindow,
            style: XText.bodyDim,
          ),
          const SizedBox(height: 8),
          Text(h.xdPath, style: XText.monoSmall),
        ],
      ]),
    );
  }
}

/// The daemon gave this process the agent role (it runs in the process tree of an agent's MCP host, D-28).
class _NotOwner extends StatelessWidget {
  const _NotOwner({super.key});

  @override
  Widget build(BuildContext context) {
    final h = AppScope.of(context).hello;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.smart_toy_outlined, color: XColors.warn, size: 20),
          SizedBox(width: 8),
          Text(context.l.gateNotOwnerTitle, style: XText.h2),
        ]),
        const SizedBox(height: 8),
        Text(
          h?.agent == null ? context.l.gateNotOwnerBody : context.l.gateNotOwnerBodyNamed(h!.agent!),
          style: XText.bodyDim,
        ),
      ]),
    );
  }
}

/// create: a new node (`init`); unlock: keys are locked (`unlock` + the window's session); login: keys are unlocked,
/// only the window's owner session is needed (`login {hold}`, x-control/2).
enum _PwMode { create, unlock, login }

class _PasswordCard extends StatefulWidget {
  const _PasswordCard({super.key, required this.mode});
  final _PwMode mode;
  bool get create => mode == _PwMode.create;

  @override
  State<_PasswordCard> createState() => _PasswordCardState();
}

class _PasswordCardState extends State<_PasswordCard> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  String? _detail;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    // A Touch ID unlock that opened the keys but not the session lands here: say why the password is asked.
    final m = AppScope.read(context);
    final err = m.touchIdGateError;
    if (widget.mode == _PwMode.login && err != null) _showTouchError(m, err);
    // Shown once: a later sign-in card starts clean.
    m.touchIdGateError = null;
  }

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Touch ID is offered on this card: unlock with the sealed slot, or sign in with a proof.
  bool _touchMode(AppModel m) => switch (widget.mode) {
        _PwMode.unlock => m.touchIdUnlockReady,
        _PwMode.login => m.touchIdReady,
        _PwMode.create => false,
      };

  Future<void> _touch() async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() {
      _error = null;
      _detail = null;
    });
    final err = widget.mode == _PwMode.unlock
        ? await m.unlockWithTouchId(reason: l.touchIdReasonUnlock)
        : await m.signInWithTouchId(reason: l.touchIdReasonSignIn);
    if (!mounted || err == null) return;
    setState(() => _showTouchError(m, err));
    _focus.requestFocus();
  }

  /// Cancelled: only the password field. Otherwise why the password is asked, or the error itself.
  void _showTouchError(AppModel m, Object err) {
    final l = context.l;
    final note = touchIdFallbackNote(l, m, err);
    if (TouchIdMixin.fallbackFor(err) == TouchIdFallback.cancelled) {
      _error = null;
      _detail = null;
    } else {
      _error = note ?? describeError(l, err);
      _detail = note == null ? errorDetail(err) : null;
    }
  }

  Future<void> _submit() async {
    final m = AppScope.read(context);
    final pw = _pw.text;
    if (widget.create) {
      if (pw.length < 8) {
        setState(() => _error = context.l.gatePasswordTooShort);
        return;
      }
      if (pw != _pw2.text) {
        setState(() => _error = context.l.gatePasswordsDiffer);
        return;
      }
    } else if (pw.isEmpty) {
      return;
    }
    setState(() {
      _error = null;
      _detail = null;
    });
    final err = switch (widget.mode) {
      _PwMode.create => await m.init(pw),
      _PwMode.unlock => await m.unlock(pw),
      _PwMode.login => await m.login(pw),
    };
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = describeError(context.l, err);
        _detail = err is XControlException && err.code == XErrorCode.wrongPassword ? null : errorDetail(err);
      });
      _pw.selection = TextSelection(baseOffset: 0, extentOffset: _pw.text.length);
    } else {
      _pw.clear();
      _pw2.clear();
    }
  }

  /// At app start, the first gate opens the Touch ID sheet by itself (D-131), once: when Touch ID is ready for this
  /// card, the app is in front, and nothing else runs.
  void _touchAtStart(AppModel m) {
    if (!m.touchIdAtStart || !_touchMode(m) || m.busy) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    m.touchIdAtStart = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_touch());
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final create = widget.create;
    final l = context.l;
    _touchAtStart(m);
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            switch (widget.mode) {
              _PwMode.create => Icons.key_outlined,
              _PwMode.unlock => Icons.lock_outline,
              _PwMode.login => Icons.login_rounded,
            },
            color: XColors.accent,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            switch (widget.mode) {
              _PwMode.create => l.gateCreateTitle,
              _PwMode.unlock => l.gateUnlockTitle,
              _PwMode.login => l.gateLoginTitle,
            },
            style: XText.h2,
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          switch (widget.mode) {
            _PwMode.create => l.gateCreateBody,
            _PwMode.unlock => l.gateUnlockBody,
            _PwMode.login => l.gateLoginBody,
          },
          style: XText.bodyDim,
        ),
        if (widget.mode == _PwMode.login && m.restoredAgents.isNotEmpty) _RestoredNote(m),
        if (_touchMode(m)) ...[
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: Key(widget.mode == _PwMode.unlock ? 'touchid-unlock' : 'touchid-signin'),
              onPressed: m.busy ? null : _touch,
              icon: const Icon(Icons.fingerprint, size: 20),
              label: Text(widget.mode == _PwMode.unlock ? l.gateUnlockTouchId : l.gateSignInTouchId),
            ),
          ),
          const SizedBox(height: 12),
          Center(child: Text(l.gateOrPassword, style: XText.meta)),
        ],
        const SizedBox(height: 20),
        TextField(
          key: const Key('password'),
          controller: _pw,
          focusNode: _focus,
          autofocus: true,
          obscureText: _obscure,
          enableSuggestions: false,
          autocorrect: false,
          style: XText.body.copyWith(fontFamily: XFonts.mono, letterSpacing: 2),
          decoration: InputDecoration(
            labelText: l.gatePassword,
            suffixIcon: IconButton(
              tooltip: _obscure ? l.commonShow : l.commonHide,
              icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onSubmitted: (_) => create ? null : _submit(),
        ),
        if (create) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('password2'),
            controller: _pw2,
            obscureText: _obscure,
            enableSuggestions: false,
            autocorrect: false,
            style: XText.body.copyWith(fontFamily: XFonts.mono, letterSpacing: 2),
            decoration: InputDecoration(labelText: l.gatePasswordAgain),
            onSubmitted: (_) => _submit(),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.error_outline, size: 16, color: XColors.danger),
            const SizedBox(width: 8),
            Expanded(child: Text(_error!, style: XText.bodyDim.copyWith(color: XColors.danger))),
          ]),
          if (_detail != null) Padding(
            padding: const EdgeInsets.only(left: 24, top: 2),
            child: Text(_detail!, style: XText.monoSmall),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          // With Touch ID above, the password's button is the second one.
          child: (_touchMode(m) ? OutlinedButton.new : FilledButton.new)(
            key: const Key('submit'),
            onPressed: m.busy ? null : _submit,
            child: m.busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.8, color: _touchMode(m) ? XColors.accent : XColors.onAccent))
                : Text(switch (widget.mode) {
                    _PwMode.create => l.gateCreateButton,
                    _PwMode.unlock => l.gateUnlockButton,
                    _PwMode.login => l.gateLoginButton,
                  }),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          switch (widget.mode) {
            _PwMode.create => l.commonSameAs('antenna init'),
            _PwMode.unlock => l.commonSameAs('antenna unlock + antenna login'),
            _PwMode.login => l.gateLoginCli,
          },
          style: XText.monoSmall,
        ),
      ]),
    );
  }
}

/// Before sign-in after an automatic update: which Code mode agents the window started again in their sessions
/// (D-103), and whether new messages wake them until the owner signs in (`agent_watch`, CONTROL §23).
class _RestoredNote extends StatelessWidget {
  const _RestoredNote(this.m);
  final AppModel m;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final names = m.restoredAgents;
    final watching = names.any(m.watchingAgent);
    final noWake = names.any((a) => m.runOf(a)?.watchUnavailable ?? false);
    return Container(
      key: const Key('gate-restored'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: XColors.accentSoft, borderRadius: BorderRadius.circular(XRadius.m)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.terminal_rounded, size: 16, color: XColors.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            [
              l.gateRestored(sanitizeVersion(m.restoredVersion ?? ''), names.join(', ')),
              if (watching) l.gateRestoredWatching else if (noWake) l.gateRestoredNoWake,
            ].join(' '),
            style: XText.meta.copyWith(color: XColors.text),
          ),
        ),
      ]),
    );
  }
}

class _Unreachable extends StatefulWidget {
  const _Unreachable({super.key});

  @override
  State<_Unreachable> createState() => _UnreachableState();
}

class _UnreachableState extends State<_Unreachable> {
  late final TextEditingController _path;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: AppScope.read(context).socketPath);
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final err = m.lastError;
    final h = m.host;
    final he = m.hostError;
    final l = context.l;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(he != null ? Icons.error_outline : Icons.power_off_outlined, color: he != null ? XColors.danger : XColors.warn, size: 20),
          const SizedBox(width: 8),
          Text(he != null ? l.gateDaemonStartFailed : l.gateDaemonUnreachable, style: XText.h2),
        ]),
        const SizedBox(height: 8),
        Text(
          h != null ? l.gateUnreachableBundled : l.gateUnreachableExternal,
          style: XText.bodyDim,
        ),
        if (he != null) ...[
          const SizedBox(height: 12),
          ErrorLine(
            he.exitCode == null
                ? describeDaemonStart(l, he)
                : l.gateErrorWithExitCode(describeDaemonStart(l, he), he.exitCode!),
            detail: he.logPath == null ? null : l.gateLogPath(he.logPath!),
          ),
          if (he.logTail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: XColors.bg2,
                borderRadius: BorderRadius.circular(XRadius.s),
                border: Border.all(color: XColors.line),
              ),
              child: SelectableText(he.logTail, style: XText.monoSmall.copyWith(color: XColors.textDim)),
            ),
          ],
          const SizedBox(height: 8),
          Text(_hintFor(l, he), style: XText.bodyDim.copyWith(fontSize: 12)),
        ] else if (err != null) ...[
          const SizedBox(height: 8),
          Text(errorDetail(err) ?? err.toString(), style: XText.monoSmall.copyWith(color: XColors.warn)),
        ],
        if (h != null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('start-daemon'),
            onPressed: m.startingDaemon ? null : m.startDaemon,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(he == null ? l.gateStartDaemon : l.gateTryAgain),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          key: const Key('socket'),
          controller: _path,
          style: XText.mono.copyWith(color: XColors.text),
          decoration: InputDecoration(labelText: l.gateSocket),
          onSubmitted: (v) => m.useSocket(v.trim()),
        ),
        const SizedBox(height: 16),
        Row(children: [
          (h != null ? OutlinedButton.new : FilledButton.new)(
            onPressed: () => m.useSocket(_path.text.trim()),
            child: Text(l.gateConnect),
          ),
          const SizedBox(width: 12),
          Text(l.gateRetryEvery, style: XText.monoSmall),
        ]),
        const SizedBox(height: 16),
        if (h == null) ...[
          _Hint(l.gateHintLocal, 'antennad   # ${l.gateHintThen}: antenna init / antenna unlock'),
          const SizedBox(height: 8),
        ],
        _Hint(l.gateHintServer, 'ssh -N -L /tmp/antenna.sock:/root/.local/share/antenna/antennad.sock server'),
      ]),
    );
  }
}

/// What happened when starting the daemon, in the app language; technical details (path, stderr) as they are.
String describeDaemonStart(AppLocalizations l, DaemonStartException e) => switch (e.reason) {
      DaemonStartFailure.spawn => l.hostSpawnFailed(e.detail),
      DaemonStartFailure.socketTimeout => l.hostSocketTimeout,
      DaemonStartFailure.exited => l.hostExited,
      DaemonStartFailure.launchctl =>
        e.detail.isEmpty ? l.hostLaunchctlCode(e.exitCode ?? -1) : 'launchctl: ${e.detail}',
    };

/// Hint for the common cause.
String _hintFor(AppLocalizations l, DaemonStartException e) {
  final t = e.logTail.toLowerCase();
  if (t.contains('already listening')) return l.gateHintAlreadyListening;
  if (t.contains('address in use') || t.contains('addrinuse')) return l.gateHintAddrInUse;
  if (t.contains('preview build `x` is still running')) return l.gateHintPreviewX;
  if (t.contains('permission')) return l.gateHintPermission;
  if (e.reason == DaemonStartFailure.launchctl) return l.gateHintLaunchctl;
  if (e.reason == DaemonStartFailure.spawn) return l.gateHintSpawn;
  return l.gateHintDefault;
}

class _Hint extends StatelessWidget {
  const _Hint(this.title, this.cmd);
  final String title;
  final String cmd;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: XColors.bg2,
          borderRadius: BorderRadius.circular(XRadius.s),
          border: Border.all(color: XColors.line),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title.toUpperCase(), style: XText.overline),
              const SizedBox(height: 4),
              SelectableText(cmd, style: XText.mono.copyWith(color: XColors.text)),
            ]),
          ),
          IconButton(
            tooltip: context.l.commonCopy,
            icon: const Icon(Icons.copy_rounded, size: 16),
            onPressed: () => Clipboard.setData(ClipboardData(text: cmd.split('   #').first)),
          ),
        ]),
      );
}

class _Footer extends StatelessWidget {
  const _Footer(this.m);
  final AppModel m;

  @override
  Widget build(BuildContext context) {
    final h = m.hello;
    final parts = <String>[
      if (h != null) h.daemon,
      if (h != null) context.l.gateFooterProtocol(h.protocol),
      if (h?.proto != null) h!.proto!,
      if (m.status != null) 'relay ${m.status!.relay}',
    ];
    return Column(children: [
      if (parts.isNotEmpty) Text(parts.join('  ·  '), style: XText.monoSmall, textAlign: TextAlign.center),
      const SizedBox(height: 4),
      Text(prettyPath(m.socketPath, Platform.environment), style: XText.monoSmall, textAlign: TextAlign.center),
    ]);
  }
}
