// SPDX-License-Identifier: AGPL-3.0-only
// The one "Secure" indicator of the conversation header (reference v3): the word follows the daemon's facts honestly
// (secure, encrypted without post-quantum, not confirmed, history differs, rekey needed), the old badge cluster is
// gone from the header, and the popover explains each fact in plain words, keeps the raw TLS and libsignal facts
// behind "Technical details", verifies the history and opens the contact card.

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/facts.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/widgets/popover.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

const _bins = CoreBinaries(daemon: '/opt/antenna/antennad', cli: '/opt/antenna/antenna', bundled: true);

Future<(AppModel, FakeDaemon)> _open(WidgetTester t, ContactInfo c) async {
  final d = FakeDaemon(contacts: [c, emily], history: demoHistory());
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
  );
  await m.connect();
  await m.select(c.linkId);
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance()));
  await t.pump(const Duration(milliseconds: 300));
  return (m, d);
}

Finder _key(String k) => find.byKey(Key(k));
Finder _inCard(Finder f) => find.descendant(of: _key('secure-details'), matching: f);

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  test('the word follows the facts', () {
    expect(SecureState.of(emily), SecureState.secure, reason: 'hybrid TLS group, v4 session, history verified');
    expect(SecureState.of(contact('A', 1, history: const HistoryStatus(state: 'unchecked'))), SecureState.secure,
        reason: 'not verified yet is not a problem: the popover says so');
    expect(SecureState.of(contact('B', 2, e2e: const E2eInfo(sessionVersion: 3), lastKx: 'X25519')),
        SecureState.encrypted, reason: 'an end-to-end session without post-quantum facts');
    expect(SecureState.of(contact('C', 3, lastKx: 'X25519')), SecureState.encrypted,
        reason: 'the latest connection fell back to a classic TLS group');
    expect(SecureState.of(contact('D', 4, e2e: const E2eInfo())), SecureState.unconfirmed,
        reason: 'no session facts: nothing is claimed');
    expect(SecureState.of(contact('E', 5, history: mismatchHistory(5))), SecureState.mismatch);
    expect(SecureState.of(contact('F', 6, history: const HistoryStatus(state: 'rolled_back'))), SecureState.rekey);
    expect(SecureState.of(contact('G', 7, history: const HistoryStatus(state: 'peer_rolled_back'))), SecureState.rekey);
    expect(SecureState.of(contact('H', 8, e2e: const E2eInfo(), history: mismatchHistory(8))), SecureState.mismatch,
        reason: 'a history problem wins');
  });

  testWidgets('one indicator in the header; its popover in plain words, raw facts behind a disclosure', (t) async {
    final (_, d) = await _open(t, emily);
    expect(_key('secure-secure'), findsOneWidget);
    expect(find.text(en.secureChip), findsOneWidget);
    // The old cluster is gone: no E2E · PQ badge, no history chip, no fact dump in the header.
    expect(find.text('E2E · PQ'), findsNothing);
    expect(find.text(en.historyVerified), findsNothing);
    expect(find.text('X25519MLKEM768'), findsNothing);

    // Hover opens it (after a short wait), leaving closes it.
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(_key('secure-indicator')));
    await t.pump(const Duration(milliseconds: 100));
    expect(_key('secure-details'), findsNothing, reason: 'not before the wait');
    await _settle(t);
    expect(_key('secure-details'), findsOneWidget);
    expect(_inCard(find.text(en.secureTitle)), findsOneWidget);
    expect(_inCard(find.text(en.secureE2e)), findsOneWidget);
    expect(_inCard(find.text(en.securePq)), findsOneWidget);
    expect(_inCard(find.text(en.netDirect)), findsOneWidget);
    expect(_inCard(find.text(en.historyVerified)), findsOneWidget);
    expect(_inCard(find.textContaining('(809)')), findsOneWidget, reason: 'the fingerprint, to compare by voice');
    expect(_inCard(find.text('X25519MLKEM768')), findsNothing, reason: 'raw facts only on request');
    await mouse.moveTo(const Offset(5, 5));
    await _settle(t);
    expect(_key('secure-details'), findsNothing);

    // A click pins it; "Technical details" shows the facts the old tooltip dumped.
    await t.tap(_key('secure-indicator'));
    await _settle(t);
    await mouse.moveTo(const Offset(5, 5));
    await _settle(t);
    expect(_key('secure-details'), findsOneWidget, reason: 'pinned by the click');
    await t.tap(_key('secure-technical'));
    await _settle(t);
    expect(_inCard(find.text('X25519MLKEM768')), findsWidgets);
    expect(_inCard(find.text('NegotiationComplete(V1)')), findsOneWidget);
    expect(_inCard(find.text(en.badgeFactsSource)), findsOneWidget);

    // Verify now asks the daemon; the card button opens the contact card.
    await t.tap(_key('secure-verify'));
    await _settle(t);
    expect(d.calls, contains('verify'));
    await t.tap(_key('secure-card'));
    await _settle(t);
    expect(_key('secure-details'), findsNothing);
    expect(find.text(en.chatHideCard), findsNothing);
    expect(t.widget<IconButton>(find.byKey(const Key('card-toggle'))).tooltip, en.chatHideCard,
        reason: 'the card is open');
  });

  testWidgets('keyboard: focus opens it, Escape closes it, Enter toggles it', (t) async {
    await _open(t, emily);
    // A key press puts the window in keyboard mode; then the indicator gets the focus.
    await t.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    final node = Focus.of(t.element(find.descendant(of: _key('secure-indicator'), matching: find.byType(GestureDetector)).first));
    node.requestFocus();
    await _settle(t);
    expect(_key('secure-details'), findsOneWidget, reason: 'keyboard focus shows it, as a tooltip would');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(t);
    expect(_key('secure-details'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(t);
    expect(_key('secure-details'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(t);
    expect(_key('secure-details'), findsNothing);
    expect(XPopover.openDelay, lessThan(const Duration(milliseconds: 400)));
  });

  testWidgets('not secure is said honestly, in the word and in the popover (en, ru)', (t) async {
    await _open(t, contact('Alex Kim', 41, history: mismatchHistory(41)));
    expect(_key('secure-mismatch'), findsOneWidget);
    expect(find.text(en.secureChipMismatch), findsOneWidget);
    expect(find.text(en.secureChip), findsNothing);
    await t.tap(_key('secure-indicator'));
    await _settle(t);
    expect(_inCard(find.text(en.secureTitleOther)), findsOneWidget);
    expect(_inCard(find.text(en.historyMismatchTooltip)), findsOneWidget);
    await t.tap(_key('secure-indicator'));
    await _settle(t);

    await _open(t, contact('Sam Lee', 42, e2e: const E2eInfo()));
    expect(_key('secure-unconfirmed'), findsOneWidget);
    expect(find.text(en.secureChipUnconfirmed), findsOneWidget);
    await t.tap(_key('secure-indicator'));
    await _settle(t);
    expect(_inCard(find.text(en.secureE2eNone)), findsOneWidget);
    await t.tap(_key('secure-indicator'));
    await _settle(t);

    await _open(t, contact('Kai Moss', 43, e2e: const E2eInfo(sessionVersion: 3), lastKx: 'X25519'));
    expect(_key('secure-encrypted'), findsOneWidget);
    await t.tap(_key('secure-indicator'));
    await _settle(t);
    expect(_inCard(find.text(en.secureE2e)), findsOneWidget);
    expect(_inCard(find.text(en.securePqNo)), findsOneWidget);
    await t.tap(_key('secure-indicator'));
    await _settle(t);

    t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    await _open(t, contact('Ann Ray', 44, history: const HistoryStatus(state: 'rolled_back')));
    expect(_key('secure-rekey'), findsOneWidget);
    expect(find.descendant(of: _key('secure-indicator'), matching: find.text(ru.secureChipRekey)), findsOneWidget);
  });

  group('"Verify now" shows a result', () {
    testWidgets('a spinner while it runs, then "matches"', (t) async {
      final c = contact('Robin Day', 51, history: const HistoryStatus(state: 'unchecked'));
      final (_, d) = await _open(t, c);
      d.verifyDelay = const Duration(milliseconds: 200);
      d.historyStatusByLink[c.linkId] = verifiedHistory(51);
      await t.tap(_key('secure-indicator'));
      await _settle(t);

      await t.tap(_key('secure-verify'));
      await t.pump();
      expect(find.descendant(of: _key('secure-verify'), matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      expect(_inCard(find.text(en.secureVerifyChecking)), findsOneWidget);
      expect(_key('secure-verify-result'), findsNothing, reason: 'no result until the daemon answers');

      await t.pump(const Duration(milliseconds: 250));
      expect(find.descendant(of: _key('secure-verify'), matching: find.byType(CircularProgressIndicator)),
          findsNothing);
      expect(_inCard(find.text(en.secureVerifyResultOk)), findsOneWidget);
    });

    testWidgets('"the history differs", with what to do', (t) async {
      final c = contact('Robin Day', 52, history: const HistoryStatus(state: 'unchecked'));
      final (_, d) = await _open(t, c);
      d.historyStatusByLink[c.linkId] = mismatchHistory(52);
      await t.tap(_key('secure-indicator'));
      await _settle(t);

      await t.tap(_key('secure-verify'));
      await _settle(t);
      expect(_inCard(find.text(en.secureVerifyResultMismatch)), findsOneWidget);
      expect(_inCard(find.text(en.secureVerifyResultOk)), findsNothing);
    });

    testWidgets('an error names what went wrong', (t) async {
      final c = contact('Robin Day', 53, history: const HistoryStatus(state: 'unchecked'));
      final (_, d) = await _open(t, c);
      d.verifyErrors[c.label] = const XControlException(XErrorCode.network, 'relay unreachable');
      await t.tap(_key('secure-indicator'));
      await _settle(t);

      await t.tap(_key('secure-verify'));
      await _settle(t);
      expect(_inCard(find.text(en.secureVerifyResultError(en.errNetwork))), findsOneWidget);
    });
  });
}
