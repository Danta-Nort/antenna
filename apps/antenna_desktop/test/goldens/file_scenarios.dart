// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for files (x-control/3): the Files section, the safe preview, files in the conversation timeline, files
// waiting in the composer for Send.

part of 'scenarios.dart';

/// Preview images (Image.memory) are decoded outside FakeAsync; otherwise the golden comes out empty.
Future<void> _decodeImages(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  final images = t.widgetList<Image>(find.byType(Image)).toList();
  await t.runAsync(() async {
    for (final i in images) {
      await precacheImage(i.image, t.element(find.byWidget(i)));
    }
  });
  await t.pump();
}

/// A thumbnail read from a file (`Image.file` with `cacheWidth: 80`), loaded into the image cache outside FakeAsync
/// before the frame is pumped: a load that a frame started inside FakeAsync never completes while `runAsync` waits.
Future<void> _cacheThumb(WidgetTester t, String path, {int width = 80}) async {
  await t.runAsync(() async {
    final done = Completer<void>();
    final stream = ResizeImage(FileImage(File(path)), width: width).resolve(ImageConfiguration.empty);
    stream.addListener(ImageStreamListener((_, _) {
      if (!done.isCompleted) done.complete();
    }, onError: (e, s) {
      if (!done.isCompleted) done.completeError(e, s);
    }));
    await done.future;
  });
}

/// A conversation with pictures as a messenger shows them (D-UI-46): a whiteboard photo waiting for the owner's
/// decision (above the frame), three photos Emily sent together as one album, a PDF as a compact row, and the owner's
/// own photo on the right. The viewer frames open the album's first picture. Every picture received is the safe preview (here the test assets), every picture sent the window's preview copy.
Future<(AppModel, FileInfo incoming)> _imagesSetup(WidgetTester t) async {
  final d = _demo();
  Uint8List asset(String name) => File('test/goldens/assets/$name').readAsBytesSync();
  final sources = [
    ('harbor.jpg', asset('photo_wide.jpg')),
    ('courtyard.jpg', asset('photo_square.jpg')),
    ('floor-plan.png', previewPagePng()),
  ];
  final album = [
    for (final (i, (name, bytes)) in sources.indexed)
      (
        demoFile(90 + i,
            from: emily,
            name: name,
            size: 240000 + i * 31000,
            mime: name.endsWith('.png') ? 'image/png' : 'image/jpeg',
            state: 'accepted',
            verdict: 'clean',
            dest: 'shared',
            at: ago(minutes: 9).add(Duration(seconds: i * 4))),
        bytes,
      ),
  ];
  final report = demoFile(94,
      from: emily,
      name: 'Q3 report.pdf',
      size: 1258291,
      mime: 'application/pdf',
      state: 'accepted',
      verdict: 'clean',
      dest: 'shared',
      at: ago(minutes: 7));
  final incoming = demoFile(95,
      from: emily, name: 'whiteboard.jpg', size: 184320, mime: 'image/jpeg', state: 'checked', verdict: 'clean',
      at: ago(minutes: 12));
  final outgoing = demoFile(96,
      from: emily, direction: 'out', name: 'terrace.jpg', size: 92160, mime: 'image/jpeg', state: 'sent',
      verdict: 'clean', at: ago(minutes: 1));
  for (final (f, bytes) in album) {
    d.fileMap[f.id] = f;
    d.previewMap[f.id] = FilePreview(kind: 'image', imagesPng: [bytes]);
  }
  d.fileMap[report.id] = report;
  d.fileMap[incoming.id] = incoming;
  d.fileMap[outgoing.id] = outgoing;
  d.previewMap[incoming.id] = FilePreview(kind: 'image', imagesPng: [asset('photo_wide.jpg')]);
  SentPreviews.instance!.store(outgoing.linkId, outgoing.id, asset('photo_wide.jpg'));
  primeImageBytesForTest(outgoing.id, asset('photo_wide.jpg'));
  d.historyMap[emily.linkId] = [
    ...?d.historyMap[emily.linkId],
    for (final (i, (f, _)) in album.indexed) fileMsg(36 + i, f, ago(minutes: 9).add(Duration(seconds: i * 4))),
    fileMsg(39, report, ago(minutes: 7)),
    fileMsg(35, incoming, ago(minutes: 12)),
    fileMsg(41, outgoing, ago(minutes: 1)),
  ]..sort((a, b) => a.seq.compareTo(b.seq));
  final m = await _model(d);
  await m.select(emily.linkId);
  return (m, album.first.$1);
}

void _defineFileScenarios() {
  _s('24_files', (t) async {
    const name = '24_files';
    final d = _demo();
    addDemoFiles(d);
    final m = await _model(d);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(const Key('nav-files')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  _s('25_file_preview', (t) async {
    const name = '25_file_preview';
    final d = _demo();
    addDemoFiles(d);
    final m = await _model(d);
    await m.select(emily.linkId);
    await _frame(t, XApp(model: m));
    await t.tap(find.byKey(Key('file-preview-${contractPdf.id.substring(0, 8)}')));
    await t.pump(const Duration(milliseconds: 400));
    await _decodeImages(t);
    await _snap(t, name);
  });

  _s('26_chat_files', (t) async {
    const name = '26_chat_files';
    final d = _demo();
    addDemoFiles(d);
    d.shareNeedsApproval['/home/owner/Documents/keys-backup.txt'] = 'ap-5e11c0';
    final m = await _model(d);
    await m.select(jordan.linkId);
    await m.shareFile(jordan.linkId, '/home/owner/Documents/keys-backup.txt');
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  // Withdrawn files (preview.5): one of ours that Jordan's older app may already have downloaded, and one Jordan sent
  // and withdrew before it was accepted here, with the receipt line.
  _s('50_file_withdrawn', (t) async {
    const name = '50_file_withdrawn';
    final d = _demo();
    final ours = demoFile(80,
        from: jordan,
        direction: 'out',
        name: 'budget-2027.xlsx',
        size: 48128,
        mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        state: 'sent',
        verdict: 'clean',
        at: ago(minutes: 8));
    final theirs = demoFile(81,
        from: jordan,
        name: 'draft-contract.pdf',
        size: 210944,
        mime: 'application/pdf',
        state: 'checked',
        verdict: 'clean',
        at: ago(minutes: 5));
    d.fileMap[ours.id] = ours.withState('withdrawn', withdrawal: 'contact_cannot_withdraw');
    d.fileMap[theirs.id] = theirs;
    d.historyMap[jordan.linkId] = [
      ...?d.historyMap[jordan.linkId],
      fileMsg(25, ours, ago(minutes: 8)),
      fileMsg(26, theirs, ago(minutes: 5)),
      withdrawReceiptMsg(27, false, theirs.messageId!, ago(minutes: 2)),
    ];
    final m = await _model(d);
    await m.select(jordan.linkId);
    await _frame(t, XApp(model: m));
    await _snap(t, name);
  });

  // Three files wait above the field (an image with its thumbnail, a document, one the secret scanner held at the last
  // Send), the caption is typed: nothing has left yet.
  _s('49_composer_staged', (t) async {
    const name = '49_composer_staged';
    final m = await _model(_demo());
    await m.select(jordan.linkId);
    final staging = OutgoingStaging.instance!;
    m
      ..stageAttachment(jordan.linkId, staging.stageBytes(previewPagePng(), 'contract-page-1.png')!)
      ..stageAttachment(jordan.linkId, staging.stageBytes(List.filled(1258291, 0x25), 'Q3 report.pdf')!);
    m.stageAttachment(jordan.linkId, staging.stageBytes('AKIA0000EXAMPLE'.codeUnits, 'keys-backup.txt')!).approvalId =
        'ap-5e11c0';
    await _cacheThumb(t, m.stagedOf(jordan.linkId).first.file.path, width: 144);
    await _frame(t, XApp(model: m));
    await t.enterText(find.byKey(const Key('composer')), 'The signed contract and the Q3 figures');
    await _snap(t, name);
  });

  _s('63_chat_images', (t) async {
    const name = '63_chat_images';
    final (m, _) = await _imagesSetup(t);
    await _frame(t, XApp(model: m));
    await _decodeImages(t);
    await _snap(t, name);
  });
  _s('63_chat_images_dark', (t) async {
    const name = '63_chat_images_dark';
    final (m, _) = await _imagesSetup(t);
    await _frame(t, _dark(m));
    await _decodeImages(t);
    await _snap(t, name);
  });

  // A chat's Media and files (D-UI-46): the album's pictures and the whiteboard as a grid, the counts of the other tabs.
  _s('92_media_files', (t) async {
    const name = '92_media_files';
    final (m, _) = await _imagesSetup(t);
    await _frame(t, XApp(model: m));
    await _decodeImages(t);
    await t.tap(find.byKey(const Key('chat-media')));
    await _decodeImages(t);
    await _snap(t, name);
  });
  _s('92_media_files_dark', (t) async {
    const name = '92_media_files_dark';
    final (m, _) = await _imagesSetup(t);
    await _frame(t, _dark(m));
    await _decodeImages(t);
    await t.tap(find.byKey(const Key('chat-media')));
    await _decodeImages(t);
    await _snap(t, name);
  });

  _s('64_image_viewer', (t) async {
    const name = '64_image_viewer';
    final (m, incoming) = await _imagesSetup(t);
    await _frame(t, XApp(model: m));
    await _decodeImages(t);
    await t.tap(find.byKey(Key('chat-picture-${incoming.id.substring(0, 8)}')));
    await _decodeImages(t);
    await _snap(t, name);
  });
  _s('64_image_viewer_dark', (t) async {
    const name = '64_image_viewer_dark';
    final (m, incoming) = await _imagesSetup(t);
    await _frame(t, _dark(m));
    await _decodeImages(t);
    await t.tap(find.byKey(Key('chat-picture-${incoming.id.substring(0, 8)}')));
    await _decodeImages(t);
    await _snap(t, name);
  });
}
