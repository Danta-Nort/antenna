// SPDX-License-Identifier: AGPL-3.0-only
// A message's text in the chat (ui/chat/bubble_text.dart, fake daemon): "Copy text" copies the whole message from the
// button beside the bubble and from its right-click menu, with a "Copied" note; a message taller than most of the chat
// is cut with "Show all", which opens a reader with the whole text and Copy all; and a drag selection keeps its start
// when the reversed chat list scrolls during the drag (a `SelectableText` let the start slide towards the pointer).

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

Future<void> _app(WidgetTester t, AppModel m, {double height = 900}) async {
  t.view.physicalSize = Size(1440, height);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 300));
}

/// The clipboard as the platform channel sees it.
List<String> _clipboard(WidgetTester t) {
  final copied = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    if (call.method == 'Clipboard.hasStrings') return <String, Object?>{'value': copied.isNotEmpty};
    return null;
  });
  addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// A crash report of [lines] numbered lines.
String _log(int lines) => [for (var i = 1; i <= lines; i++) 'line $i: Thread $i Crashed:: com.apple.main-thread'].join('\n');

Future<(FakeDaemon, AppModel, HistoryItem)> _chatWith(String text) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  final item = msg(90, false, text, fixedNow.subtract(const Duration(minutes: 1)));
  d.historyMap[emily.linkId] = [...?d.historyMap[emily.linkId], item];
  final m = await _model(d);
  await m.select(emily.linkId);
  return (d, m, item);
}

Finder _text(HistoryItem item) => find.byKey(Key('bubble-text-${item.id}'));

void main() {
  testWidgets('Copy text beside the bubble on hover and in its right-click menu copies the whole message', (t) async {
    final copied = _clipboard(t);
    const text = 'The build is green.\nTwo warnings in the docs job.';
    final (_, m, item) = await _chatWith(text);
    await _app(t, m);

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(_text(item)));
    await t.pump();
    await t.tap(find.byKey(Key('copy-text-${item.id}')));
    await t.pump();
    expect(copied, [text]);
    expect(find.text(en.bubbleCopied), findsOneWidget);

    await t.tapAt(t.getCenter(_text(item)), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await t.pump();
    await t.tap(find.text(en.bubbleCopyText).last);
    await t.pump();
    expect(copied, [text, text], reason: 'the whole message, not the word under the pointer');
  });

  testWidgets('a message taller than most of the chat is cut, and Show all opens all of it with Copy all', (t) async {
    final copied = _clipboard(t);
    final text = _log(300);
    final (_, m, item) = await _chatWith(text);
    await _app(t, m);
    final shown = t.getSize(_text(item)).height;
    final chat = t.getSize(find.byKey(const Key('chat-messages'))).height;
    expect(shown, lessThanOrEqualTo(chat * 0.6 + 1), reason: 'cut to about 60% of the chat');
    expect(find.byKey(Key('show-all-${item.id}')), findsOneWidget);

    await t.tap(find.byKey(Key('show-all-${item.id}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('message-reader')), findsOneWidget);
    expect(t.widget<SelectableText>(find.byKey(const Key('message-reader-text'))).data, text);
    await t.tap(find.byKey(const Key('message-reader-copy')));
    await t.pump();
    expect(copied, [text]);

    // A short message is not cut.
    final (_, m2, short) = await _chatWith('Thanks!');
    await _app(t, m2);
    expect(find.byKey(Key('show-all-${short.id}')), findsNothing);
  });

  testWidgets('a drag selection keeps its start when the chat list scrolls during the drag', (t) async {
    final copied = _clipboard(t);
    // Tall, but not cut: a short window makes the chat short, and the cut is measured against a taller one.
    final text = _log(24);
    final (_, m, item) = await _chatWith(text);
    await _app(t, m, height: 1000);
    final list = t.widget<ListView>(find.byKey(const Key('chat-messages'))).controller!;
    expect(find.byKey(Key('show-all-${item.id}')), findsNothing);

    // Read back a little first, so the list can scroll towards the newest during the drag.
    list.jumpTo(150);
    await t.pump();
    await t.pump();
    // Start at the first line, drag a little, then the list scrolls towards the newest (as a selection that reaches
    // the bottom edge, or a wheel, scrolls it): the text moves up under the pointer, then the pointer moves on.
    final box = t.getRect(_text(item));
    final start = box.topLeft + const Offset(2, 6);
    final drag = await t.startGesture(start, kind: PointerDeviceKind.mouse);
    await t.pump(const Duration(milliseconds: 50));
    await drag.moveTo(start + const Offset(40, 30));
    await t.pump();
    list.jumpTo(list.position.pixels - 120);
    await t.pump();
    await drag.moveTo(start + const Offset(200, 160));
    await t.pump();
    await drag.up();
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.control);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.control);
    await t.pump();
    expect(copied, isNotEmpty, reason: 'something is selected');
    expect(copied.last, startsWith('line 1: Thread 1'), reason: 'the selection still starts where the drag began');
  });
}
