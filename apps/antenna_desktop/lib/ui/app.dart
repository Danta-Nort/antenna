// SPDX-License-Identifier: AGPL-3.0-only
// App root: theme (light by default, dark from the system or by choice), language (English by default, Russian from
// the system or by choice), access to the model, the screen for the current phase (before sign-in / main), and the
// system notification when an agent waits for approval while the window is not in focus (D-84): here or on another
// own computer, and once more when a request is about to run out (D-114).

import 'dart:async';

import 'package:flutter/material.dart';

import '../host/notifier.dart';
import '../host/window_chrome.dart';
import '../l10n/l10n.dart';
import '../protocol/x_control.dart';
import '../state/app_model.dart';
import '../state/appearance.dart';
import '../state/approval_alerts.dart';
import '../theme/x_theme.dart';
import 'app_scope.dart';
import 'approvals/approvals_view.dart';
import 'gate/gate_screen.dart';
import 'home/chat_menu.dart' show messageNotification;
import 'home/home_screen.dart';

class XApp extends StatefulWidget {
  XApp({super.key, required this.model, Appearance? appearance, this.navigatorKey, this.notifier})
      : appearance = appearance ?? Appearance();
  final AppModel model;
  final Appearance appearance;

  /// The root navigator (main.dart: the "agents are running" question when the window closes).
  final GlobalKey<NavigatorState>? navigatorKey;

  /// System notifications; `null`: none (tests, an OS without a known tool).
  final SystemNotifier? notifier;

  @override
  State<XApp> createState() => _XAppState();
}

class _XAppState extends State<XApp> with WidgetsBindingObserver {
  late XPalette _palette = _resolve();
  late Locale _locale = _resolveLocale();
  StreamSubscription<ApprovalInfo>? _approvals;
  StreamSubscription<ApprovalAlert>? _alerts;
  StreamSubscription<EscalationInfo>? _questions;
  StreamSubscription<ChatNotice>? _messages;

  /// When each chat last notified (one notification for a burst of messages in one chat).
  final _noticeAt = <String, DateTime>{};

  /// The window has the keyboard focus (`resumed`); `inactive` or `hidden` means the owner looks elsewhere.
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.appearance.addListener(_update);
    XColors.palette = _palette;
    final state = WidgetsBinding.instance.lifecycleState;
    _focused = state == null || state == AppLifecycleState.resumed;
    _approvals = widget.model.newApprovals.listen(_onNewApproval);
    _alerts = widget.model.approvalAlerts.listen(_onApprovalAlert);
    _questions = widget.model.newQuestions.listen(_onNewQuestion);
    _messages = widget.model.newMessages.listen(_onNewMessage);
    _bindCodeWake();
  }

  /// "Wake on new messages" per agent lives in the window settings file (Code mode, D-UI-23).
  void _bindCodeWake() {
    final m = widget.model;
    final look = widget.appearance;
    m.codeWakeOff
      ..clear()
      ..addAll(look.codeWakeOff);
    m.onCodeWakeChanged = look.setCodeWakeOff;
  }

  @override
  void didUpdateWidget(XApp old) {
    super.didUpdateWidget(old);
    if (old.appearance != widget.appearance) {
      old.appearance.removeListener(_update);
      widget.appearance.addListener(_update);
      _update();
    }
    if (old.model != widget.model) {
      unawaited(_approvals?.cancel());
      _approvals = widget.model.newApprovals.listen(_onNewApproval);
      unawaited(_alerts?.cancel());
      _alerts = widget.model.approvalAlerts.listen(_onApprovalAlert);
      unawaited(_questions?.cancel());
      _questions = widget.model.newQuestions.listen(_onNewQuestion);
      unawaited(_messages?.cancel());
      _messages = widget.model.newMessages.listen(_onNewMessage);
    }
    if (old.model != widget.model || old.appearance != widget.appearance) _bindCodeWake();
  }

  @override
  void dispose() {
    unawaited(_approvals?.cancel());
    unawaited(_alerts?.cancel());
    unawaited(_questions?.cancel());
    unawaited(_messages?.cancel());
    widget.appearance.removeListener(_update);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _focused = state == AppLifecycleState.resumed;

  /// A message in a chat whose setting asks for it (D-UI-32): in focus, the list's counts are enough; otherwise a
  /// system notification with the chat's name, never the text (SPEC §11), at most one per chat in 10 seconds.
  void _onNewMessage(ChatNotice n) {
    final notifier = widget.notifier;
    if (notifier == null || _focused) return;
    final m = widget.model;
    final c = m.contactById(n.linkId);
    if (c == null) return;
    final key = '${n.linkId}/${n.chat.id}';
    final now = DateTime.now();
    final last = _noticeAt[key];
    if (last != null && now.difference(last) < const Duration(seconds: 10)) return;
    _noticeAt[key] = now;
    final (title, body) = messageNotification(lookupAppLocalizations(_locale), m, c, n.chat);
    unawaited(notifier.show(title: title, body: body));
  }

  /// An agent asks for approval: in focus, the card in the conversation and the counter are enough; otherwise a
  /// system notification (facts and the time left only, never the request text).
  void _onNewApproval(ApprovalInfo a) => _onApprovalAlert(ApprovalAlert.here(a, widget.model.now()));

  /// A request on another own computer, or one about to run out: the same rule as [_onNewApproval].
  void _onApprovalAlert(ApprovalAlert a) {
    final n = widget.notifier;
    if (n == null || _focused) return;
    final (title, body) = approvalNotification(lookupAppLocalizations(_locale), a);
    unawaited(n.show(title: title, body: body));
  }

  /// An agent asks a question (D-118): in focus, the card and the counter are enough; otherwise a system notification
  /// with the agent's name only, never the question (it may carry what the agent read from contacts).
  void _onNewQuestion(EscalationInfo q) {
    final n = widget.notifier;
    if (n == null || _focused) return;
    final l = lookupAppLocalizations(_locale);
    unawaited(n.show(title: l.notifyQuestionTitle, body: l.notifyQuestionBody(q.agent)));
  }

  @override
  void didChangePlatformBrightness() => _update();

  @override
  void didChangeLocales(List<Locale>? locales) => _update();

  XPalette _resolve() => switch (widget.appearance.choice) {
        ThemeChoice.light => XPalette.light,
        ThemeChoice.dark => XPalette.dark,
        ThemeChoice.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark
            ? XPalette.dark
            : XPalette.light,
      };

  Locale _resolveLocale() =>
      resolveLanguage(widget.appearance.lang, WidgetsBinding.instance.platformDispatcher.locales);

  void _update() {
    // Language: strings come through Localizations (an InheritedWidget), so a MaterialApp with a new locale rebuilds
    // only the widgets that depend on it, and state (text fields, selection, scrolling) is kept.
    final locale = _resolveLocale();
    if (locale != _locale) setState(() => _locale = locale);
    final next = _resolve();
    if (identical(next, _palette)) return;
    setState(() {
      _palette = next;
      XColors.palette = next;
    });
    // Colors are read from XColors at build time: rebuild the whole tree, keeping state (text fields, selection, scrolling).
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }

  @override
  Widget build(BuildContext context) {
    XColors.palette = _palette;
    // macOS: the title bar follows the app's theme, not the system's.
    unawaited(WindowChrome.apply(dark: _palette.isDark, color: _palette.nav));
    return AppearanceScope(
      appearance: widget.appearance,
      child: AppScope(
        model: widget.model,
        child: MaterialApp(
          navigatorKey: widget.navigatorKey,
          title: 'Antenna',
          debugShowCheckedModeBanner: false,
          locale: _locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: buildXTheme(_palette),
          // The XColors palette switches at once, so the Material theme does too, without the animated transition
          // (otherwise there would be 200 ms of mixed colors).
          themeAnimationDuration: Duration.zero,
          home: const _Root(),
        ),
      ),
    );
  }
}

/// Access to the theme and language choice (the Settings screen).
class AppearanceScope extends InheritedNotifier<Appearance> {
  const AppearanceScope({super.key, required Appearance appearance, required super.child}) : super(notifier: appearance);

  static Appearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;

  /// Without subscribing to changes (tap handlers, `initState`).
  static Appearance? read(BuildContext context) => context.getInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    return AnimatedSwitcher(
      duration: XMotion.normal,
      child: m.phase == Phase.unlocked && !m.notOwner
          ? const HomeScreen(key: ValueKey('home'))
          : const GateScreen(key: ValueKey('gate')),
    );
  }
}
