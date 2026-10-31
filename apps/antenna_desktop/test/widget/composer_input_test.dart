// SPDX-License-Identifier: AGPL-3.0-only
// What the composer takes from other apps (fake daemon): files dropped and then deleted by their source at once (the
// macOS screenshot thumbnail) are sent from the window's copy; the macOS drop view's messages (staged files, image
// data, promised files that did not arrive, drops outside the conversation); files wait as chips until Send (the
// paperclip, drops and pasted images; ✕; files in order, then the caption; a refused file keeps its chip with the
// reason or an approval while the others go; each chat keeps its own, drafts.dart); paste with text only, text next to
// an image (text wins), an image alone
// (a chip that stays with its contact); and text that a dictation app pastes with a synthetic Cmd+V, which the macOS
// Runner hands over (`antenna/paste`).

import 'dart:io';

import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/host/paste.dart';
import 'package:antenna_desktop/host/window_drop.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/chat/attachments.dart';
import 'package:antenna_desktop/ui/files/file_actions.dart';
import 'package:antenna_desktop/ui/files/file_drop.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/file_fixtures.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);

Future<AppModel> _model(FakeDaemon d) async {
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  await m.select(jordan.linkId);
  return m;
}

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
}

FakeDaemon _demo() => FakeDaemon(contacts: demoContacts(), history: demoHistory());

OutgoingStaging get _staging => OutgoingStaging.instance!;

/// The system clipboard as the platform channel answers: [text] (`null`: no text at all).
void _clipboard(WidgetTester t, String? text) {
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.getData':
        return text == null ? null : <String, Object?>{'text': text};
      case 'Clipboard.hasStrings':
        return <String, Object?>{'value': text != null && text.isNotEmpty};
    }
    return null;
  });
  addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

class _Images implements ClipboardImages {
  _Images(this.bytes);
  final Uint8List? bytes;
  int reads = 0;

  @override
  Future<Uint8List?> read() async {
    reads++;
    return bytes;
  }
}

_Images _images(Uint8List? bytes) {
  final saved = ClipboardImages.instance;
  final i = _Images(bytes);
  ClipboardImages.instance = i;
  addTearDown(() => ClipboardImages.instance = saved);
  return i;
}

TextEditingController _field(WidgetTester t) => t.widget<TextField>(find.byKey(const Key('composer'))).controller!;

/// "Hello world" in the composer with "world" selected.
Future<void> _helloWorld(WidgetTester t) async {
  await t.tap(find.byKey(const Key('composer')));
  await t.enterText(find.byKey(const Key('composer')), 'Hello world');
  _field(t).selection = const TextSelection(baseOffset: 6, extentOffset: 11);
  await t.pump();
}

/// Cmd+V on a Mac, Ctrl+V elsewhere: the keys a person presses.
Future<void> _pressPaste(WidgetTester t) async {
  final mod = defaultTargetPlatform == TargetPlatform.macOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
  await t.sendKeyDownEvent(mod);
  await t.sendKeyEvent(LogicalKeyboardKey.keyV);
  await t.sendKeyUpEvent(mod);
  await t.pump(const Duration(milliseconds: 50));
}

/// Every file waiting in the composer: a picture's square and any other file's chip, in their order.
final _chips = find.byWidgetPredicate((w) => w is AttachmentChip || w is AttachmentTile);

List<String> _chipNames(WidgetTester t) => [
      for (final w in t.widgetList(_chips)) w is AttachmentTile ? w.a.name : (w as AttachmentChip).a.name,
    ];

Future<void> _pressSend(WidgetTester t) async {
  await t.tap(find.byKey(const Key('send')));
  await t.pump(const Duration(milliseconds: 300));
}

class _Chooser implements FileChooser {
  _Chooser(this.path);
  final String path;
  @override
  Future<String?> pick(String confirm) async => path;
}

/// A real file to attach, in a temporary folder removed after the test.
File _file(String name, List<int> bytes) {
  final dir = Directory.systemTemp.createTempSync('attach-src-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return File('${dir.path}/$name')..writeAsBytesSync(bytes);
}

final _desktops = TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.linux});

void main() {
  group('drop', () {
    testWidgets('a file its source deletes right after the drop is sent from the window\'s copy', (t) async {
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      final dir = Directory.systemTemp.createTempSync('drop-src-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ctx = t.element(find.byType(HomeScreen));

      // Negative control, the bug as it was: the path goes to the daemon as it is, and the file is gone by then.
      final saved = OutgoingStaging.instance;
      OutgoingStaging.instance = null;
      final lost = File('${dir.path}/Screenshot 2026-10-05 at 14.03.21.png')..writeAsBytesSync(png);
      await t.runAsync(() async {
        final dropping = dropFilesForTest(ctx, jordan.linkId, [lost.path]);
        lost.deleteSync();
        await dropping;
      });
      OutgoingStaging.instance = saved;
      await t.pump();
      await _pressSend(t);
      expect(d.sharedContent[lost.path], isNull, reason: 'without staging the daemon finds nothing');

      // macOS removes the screenshot thumbnail's temporary file as soon as the drop ends.
      final shot = File('${dir.path}/Screenshot 2026-10-05 at 14.03.22.png')..writeAsBytesSync(png);
      await t.runAsync(() async {
        final dropping = dropFilesForTest(ctx, jordan.linkId, [shot.path]);
        shot.deleteSync();
        await dropping;
      });
      await t.pump();
      expect(_chipNames(t), ['Screenshot 2026-10-05 at 14.03.22.png']);
      await _pressSend(t);
      final sent = d.shared.last;
      expect(_staging.owns(sent), isTrue, reason: 'the window sent its copy');
      expect(d.sharedContent[sent], png, reason: 'the daemon read the whole screenshot');
      expect(File(sent).existsSync(), isFalse, reason: 'the copy is deleted once the daemon has it');
      expect(m.filesOfLink(jordan.linkId).any((f) => f.name == 'Screenshot 2026-10-05 at 14.03.22.png'), isTrue,
          reason: 'the contact sees the original name');
    });

    testWidgets('macOS drop view: files dropped on the composer become chips, go on Send, then the copies go',
        (t) async {
      WindowDrop.native = true;
      addTearDown(() => WindowDrop.native = Platform.isMacOS);
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      final at = t.getCenter(find.byKey(const Key('composer')));
      await WindowDrop.instance.handle(MethodCall('entered', [at.dx, at.dy]));
      await t.pump();
      expect(find.byKey(const Key('drop-overlay')), findsOneWidget, reason: 'the composer is part of the drop zone');
      expect(find.text(en.filesDropTitle(jordan.label)), findsOneWidget);

      // What the view stages before the drop ends: a cloned file, and image data written as a file.
      final file = _staging.stageBytes(png, 'Screenshot 2026-10-05 at 14.03.22.png')!;
      final image = _staging.stageBytes(png, 'image-2026-10-05-140322.png')!;
      await WindowDrop.instance.handle(MethodCall('dropped', {
        'x': at.dx,
        'y': at.dy,
        'items': [
          {'path': file.path, 'staged': true},
          {'path': image.path, 'staged': true},
        ],
        'failed': 0,
      }));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('drop-overlay')), findsNothing);
      expect(_chipNames(t), ['Screenshot 2026-10-05 at 14.03.22.png', 'image-2026-10-05-140322.png']);
      expect(d.shared, isEmpty, reason: 'nothing leaves before Send');
      await _pressSend(t);
      expect(d.shared, [file.path, image.path]);
      expect(d.sharedContent[file.path], png);
      expect(File(file.path).existsSync(), isFalse);
      expect(File(image.path).existsSync(), isFalse);
    });

    testWidgets('macOS drop view: outside the conversation nothing is sent and the copy goes; lost promises are said',
        (t) async {
      WindowDrop.native = true;
      addTearDown(() => WindowDrop.native = Platform.isMacOS);
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      final outside = _staging.stageBytes(png, 'image.png')!;
      await WindowDrop.instance.handle(MethodCall('dropped', {
        'x': 5.0,
        'y': 5.0,
        'items': [
          {'path': outside.path, 'staged': true},
        ],
      }));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.shared, isEmpty);
      expect(File(outside.path).existsSync(), isFalse, reason: 'nobody took the drop');

      final at = t.getCenter(find.byType(FileDropZone));
      await WindowDrop.instance.handle(MethodCall('dropped', {'x': at.dx, 'y': at.dy, 'items': <Object?>[], 'failed': 2}));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text(en.filesDropNotReceived(2)), findsOneWidget);
    });

    testWidgets('a copy held for approval stays for the retry; ✕ deletes it; the chip shows no staging path',
        (t) async {
      WindowDrop.native = true;
      addTearDown(() => WindowDrop.native = Platform.isMacOS);
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      final image = _staging.stageBytes(png, 'image-2026-10-05-140322.png')!;
      d.shareNeedsApproval[image.path] = 'ap-1';
      final at = t.getCenter(find.byType(FileDropZone));
      await WindowDrop.instance.handle(MethodCall('dropped', {
        'x': at.dx,
        'y': at.dy,
        'items': [
          {'path': image.path, 'staged': true},
        ],
      }));
      await t.pump(const Duration(milliseconds: 300));
      await _pressSend(t);
      final a = m.stagedOf(jordan.linkId).single;
      expect(find.byKey(Key('attachment-approve-${a.id}')), findsOneWidget);
      expect(find.text(en.composerAttachmentSecret), findsOneWidget);
      expect(File(image.path).existsSync(), isTrue, reason: 'the approval is bound to this path');
      expect(find.textContaining(_staging.root), findsNothing, reason: 'the chip does not show the window\'s folder');
      await t.tap(find.byKey(Key('attachment-remove-${a.id}')));
      await t.pump(const Duration(milliseconds: 300));
      expect(File(image.path).existsSync(), isFalse);
      expect(m.stagedOf(jordan.linkId), isEmpty);
    });
  });

  group('staged attachments', () {
    testWidgets('two files and a caption: nothing before Send; ✕ removes one; files go in order, then the caption',
        (t) async {
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      final report = _file('Q3 report.pdf', List.filled(2048, 7));
      final photo = _file('team.png', png);
      final draft = _file('draft.txt', [1, 2, 3]);
      final saved = FileChooser.instance;
      FileChooser.instance = _Chooser(report.path);
      addTearDown(() => FileChooser.instance = saved);
      final home = t.element(find.byType(HomeScreen));
      await t.runAsync(() => pickAndAttach(home));
      await t.runAsync(() => dropFilesForTest(home, jordan.linkId, [photo.path, draft.path]));
      await t.pump();
      expect(_chipNames(t), ['Q3 report.pdf', 'team.png', 'draft.txt']);
      expect(find.text('2.0 KB'), findsOneWidget, reason: 'the size on the chip');
      await t.tap(find.byKey(Key('attachment-remove-${m.stagedOf(jordan.linkId)[2].id}')));
      await t.pump();
      expect(_chipNames(t), ['Q3 report.pdf', 'team.png']);
      await t.enterText(find.byKey(const Key('composer')), 'Figures for Q3');
      await t.pump(const Duration(milliseconds: 300));
      expect(d.shared, isEmpty);
      expect(d.calls.where((c) => c == 'send'), isEmpty, reason: 'nothing leaves before Send');

      d.calls.clear();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 300));
      expect(d.shared.map((p) => p.split('/').last), ['Q3 report.pdf', 'team.png']);
      expect(d.calls.where((c) => c == 'share_file' || c == 'send'), ['share_file', 'share_file', 'send'],
          reason: 'the files first, then the caption');
      expect(d.historyMap[jordan.linkId]!.last.text, 'Figures for Q3');
      expect(_chips, findsNothing);
      expect(_field(t).text, isEmpty);
      expect(Directory(_staging.root).listSync(), isEmpty, reason: 'every copy is gone after the send');
    });

    testWidgets('a refused file keeps its chip with the reason; the others go; the caption waits for it', (t) async {
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      final big = _file('backup.tar', [1]);
      final photo = _file('team.png', png);
      await t.runAsync(() => dropFilesForTest(t.element(find.byType(HomeScreen)), jordan.linkId, [big.path, photo.path]));
      await t.pump();
      final refused = m.stagedOf(jordan.linkId).first;
      d.shareErrors[refused.file.path] = const XControlException('file_quota_exceeded', 'the daily volume is used up');
      await t.enterText(find.byKey(const Key('composer')), 'two files');
      await _pressSend(t);
      expect(d.shared.map((p) => p.split('/').last), ['backup.tar', 'team.png']);
      expect(m.filesOfLink(jordan.linkId).any((f) => f.name == 'team.png'), isTrue);
      expect(_chipNames(t), ['backup.tar'], reason: 'the refused one stays');
      expect(find.text(en.filesErrQuota), findsOneWidget, reason: 'with the reason on its chip');
      expect(_field(t).text, 'two files', reason: 'the caption is not lost, and not sent without its file');
      expect(d.calls, isNot(contains('send')));

      await t.tap(find.byKey(Key('attachment-remove-${refused.id}')));
      await t.pump();
      await _pressSend(t);
      expect(d.historyMap[jordan.linkId]!.last.text, 'two files');
    });

    testWidgets('another chat opened while the files go: the caption stays in its draft, not sent there', (t) async {
      final d = _demo()..shareDelay = const Duration(milliseconds: 400);
      final m = await _model(d);
      await _app(t, m);
      final photo = _file('team.png', png);
      await t.runAsync(() => dropFilesForTest(t.element(find.byType(HomeScreen)), jordan.linkId, [photo.path]));
      await t.pump();
      await t.enterText(find.byKey(const Key('composer')), 'for Jordan only');
      await t.tap(find.byKey(const Key('send')));
      await t.pump(const Duration(milliseconds: 100));
      await m.select(emily.linkId);
      await t.pump(const Duration(milliseconds: 600));
      expect(d.shared, hasLength(1), reason: 'the file went to Jordan');
      expect(d.calls, isNot(contains('send')), reason: 'the caption did not go to Emily');
      expect(_field(t).text, isEmpty, reason: "Emily's composer has her own draft");
      expect(m.draftTextOf(jordan.linkId, m.openThreadOf(jordan.linkId)), 'for Jordan only');
    });

    testWidgets('a secret: "Approve and send" on the chip asks the password, then sends that file with approval_id',
        (t) async {
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      final keys = _file('keys-backup.txt', 'AKIA0000'.codeUnits);
      await t.runAsync(() => dropFilesForTest(t.element(find.byType(HomeScreen)), jordan.linkId, [keys.path]));
      await t.pump();
      final a = m.stagedOf(jordan.linkId).single;
      d.shareNeedsApproval[a.file.path] = 'ap-5e11c0';
      await _pressSend(t);
      expect(a.approvalId, 'ap-5e11c0');
      d.approvalList = [shareApproval('ap-5e11c0', to: jordan)];
      await t.tap(find.byKey(Key('attachment-approve-${a.id}')));
      await t.pump(const Duration(milliseconds: 300));
      await t.enterText(find.byKey(const Key('owner-password')), d.password);
      await t.tap(find.byKey(const Key('password-ok')));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.passwords['approve'], d.password);
      expect(d.shared.where((p) => p == a.file.path), hasLength(2), reason: 'retried with approval_id');
      expect(_chips, findsNothing);
    });
  });

  group('paste', () {
    testWidgets('text only: into the field at the cursor, replacing the selection', (t) async {
      final m = await _model(_demo());
      await _app(t, m);
      _clipboard(t, 'dictated text 123');
      final images = _images(png);
      await _helloWorld(t);
      await _pressPaste(t);
      expect(_field(t).text, 'Hello dictated text 123');
      expect(_field(t).selection, const TextSelection.collapsed(offset: 23));
      expect(images.reads, 0);
      expect(_chips, findsNothing);
    }, variant: _desktops);

    testWidgets('text next to an image (a spreadsheet cell, rich text): the text wins, the image is ignored', (t) async {
      final m = await _model(_demo());
      await _app(t, m);
      _clipboard(t, 'Q3 total');
      final images = _images(png);
      await _helloWorld(t);
      await _pressPaste(t);
      expect(_field(t).text, 'Hello Q3 total');
      expect(images.reads, 0, reason: 'with text on the clipboard the image is not even read');
      expect(_chips, findsNothing);
    }, variant: _desktops);

    testWidgets('an image alone: waits above the field for its contact, goes with Enter, the copy is deleted',
        (t) async {
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      _clipboard(t, null);
      _images(png);
      await _helloWorld(t);
      await _pressPaste(t);
      expect(_field(t).text, 'Hello world', reason: 'nothing goes into the field');
      expect(_chips, findsOneWidget);
      expect(find.text(en.composerAttachmentsHint(en.chatAgentTitle(jordan.label, 'claude-backend'))), findsOneWidget,
          reason: "the exact recipient: Jordan's chat on screen is the one with claude-backend");
      final name = _chipNames(t).single;
      expect(name, matches(RegExp(r'^image-\d{4}-\d\d-\d\d-\d{6}\.png$')));
      expect(d.shared, isEmpty, reason: 'nothing leaves before Send');

      // Another chat: the image does not follow; a message there goes without it.
      await m.select(emily.linkId);
      await t.pump(const Duration(milliseconds: 300));
      expect(_chips, findsNothing);
      await t.enterText(find.byKey(const Key('composer')), 'hi Emily');
      await t.tap(find.byKey(const Key('send')));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.shared, isEmpty);

      await m.select(jordan.linkId);
      await t.pump(const Duration(milliseconds: 300));
      expect(_chips, findsOneWidget);
      await t.enterText(find.byKey(const Key('composer')), 'the chart');
      await t.tap(find.byKey(const Key('send')));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.historyMap[jordan.linkId]!.last.text, 'the chart', reason: 'the caption after the image');
      expect(d.shared, hasLength(1));
      expect(d.shared.single, endsWith('/$name'));
      expect(d.sharedContent[d.shared.single], png);
      expect(File(d.shared.single).existsSync(), isFalse);
      expect(_chips, findsNothing);
    }, variant: _desktops);

    testWidgets('two images pasted within a second: two attachments with their own names, both sent', (t) async {
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      _clipboard(t, null);
      _images(png);
      await t.tap(find.byKey(const Key('composer')));
      await _pressPaste(t);
      await _pressPaste(t);
      final names = _chipNames(t);
      expect(names, hasLength(2));
      expect(names.toSet(), hasLength(2));
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 300));
      expect(d.shared.map((p) => p.split('/').last).toSet(), names.toSet());
      expect(_chips, findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('an attachment can be removed: nothing is sent and the copy is deleted', (t) async {
      final d = _demo();
      final m = await _model(d);
      await _app(t, m);
      _clipboard(t, null);
      _images(png);
      await t.tap(find.byKey(const Key('composer')));
      await _pressPaste(t);
      final a = m.stagedOf(jordan.linkId).single;
      final copies = Directory(_staging.root).listSync().length;
      await t.tap(find.byKey(Key('attachment-remove-${a.id}')));
      await t.pump();
      expect(_chips, findsNothing);
      expect(Directory(_staging.root).listSync().length, copies - 1);
      await t.tap(find.byKey(const Key('send')));
      await t.pump(const Duration(milliseconds: 300));
      expect(d.shared, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('synthetic paste from the macOS Runner (dictation apps)', () {
    testWidgets('the captured text lands at the cursor even after the app restored the old clipboard', (t) async {
      final m = await _model(_demo());
      await _app(t, m);
      // Superwhisper with "Restore clipboard": by the time anything reads the clipboard, the old content is back.
      _clipboard(t, 'old clipboard');
      await _helloWorld(t);
      await PasteBridge.instance.handle(const MethodCall('paste', {'text': 'dictated text 123'}));
      await t.pump();
      expect(_field(t).text, 'Hello dictated text 123');
      expect(_field(t).selection, const TextSelection.collapsed(offset: 23));
    });

    testWidgets('no text on the pasteboard: the composer\'s paste (an image becomes an attachment)', (t) async {
      final m = await _model(_demo());
      await _app(t, m);
      _clipboard(t, null);
      _images(png);
      await t.tap(find.byKey(const Key('composer')));
      await t.pump();
      await PasteBridge.instance.handle(const MethodCall('paste', <String, Object?>{}));
      await t.pump(const Duration(milliseconds: 50));
      expect(_chips, findsOneWidget);
    });

    testWidgets('outside a text field (the agent\'s terminal): the focused widget\'s own paste', (t) async {
      var pasted = 0;
      await t.pumpWidget(MaterialApp(
        home: Actions(
          actions: {
            PasteTextIntent: CallbackAction<PasteTextIntent>(onInvoke: (_) {
              pasted++;
              return null;
            }),
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ));
      await t.pump();
      await PasteBridge.instance.handle(const MethodCall('paste', {'text': 'ls -la'}));
      expect(pasted, 1, reason: 'the terminal pastes as a terminal does (bracketed), not typed keys');
    });

    testWidgets('the Runner\'s clipboard reader: PNG bytes, no image, no Runner, a failure', (t) async {
      final reader = RunnerClipboardImages();
      final m = t.binding.defaultBinaryMessenger;
      addTearDown(() => m.setMockMethodCallHandler(RunnerClipboardImages.channel, null));
      final calls = <String>[];
      Object? answer = png;
      m.setMockMethodCallHandler(RunnerClipboardImages.channel, (call) async {
        calls.add(call.method);
        if (answer case final Exception e) throw e;
        return answer;
      });
      expect(await reader.read(), png);
      expect(calls, ['image']);
      answer = null;
      expect(await reader.read(), isNull, reason: 'text only on the clipboard');
      answer = Uint8List(0);
      expect(await reader.read(), isNull);
      answer = PlatformException(code: 'encode_failed');
      expect(await reader.read(), isNull);
      // A Runner without the channel (an older build): the call has no handler on the other side.
      answer = MissingPluginException();
      expect(await reader.read(), isNull);
    });

    testWidgets('a read-only field takes nothing', (t) async {
      final c = TextEditingController(text: 'fixed');
      addTearDown(c.dispose);
      await t.pumpWidget(MaterialApp(home: Material(child: TextField(controller: c, readOnly: true, autofocus: true))));
      await t.pump();
      await PasteBridge.instance.handle(const MethodCall('paste', {'text': 'x'}));
      await t.pump();
      expect(c.text, 'fixed');
    });
  });
}
