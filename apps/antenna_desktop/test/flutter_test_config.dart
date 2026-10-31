// SPDX-License-Identifier: AGPL-3.0-only
// For all tests: the app's real fonts instead of the Ahem test font, so golden screenshots show text and icons the
// way users see them (fonts come from the same FontManifest as in the app). The window's staging folder for outgoing
// copies and its sent-image previews are temporary ones, removed after the file's tests: no test writes into the home
// directory.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/outgoing_staging.dart';
import 'package:antenna_desktop/host/sent_previews.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadAppFonts();
  // Not created here: a test file whose tests are all filtered out (`--exclude-tags live`) runs no tear-down, so an
  // eager folder would be left behind. The staging creates it on first use; the tear-down removes it.
  final staging = Directory('${Directory.systemTemp.path}/antenna-staging-$pid-${DateTime.now().microsecondsSinceEpoch}');
  OutgoingStaging.instance = OutgoingStaging('${staging.path}/outgoing');
  SentPreviews.instance = SentPreviews('${staging.path}/sent-previews');
  tearDownAll(() {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  });
  await testMain();
}

Future<void> loadAppFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<Object?>;
  for (final f in manifest.cast<Map<String, Object?>>()) {
    final family = f['family']! as String;
    final loader = FontLoader(family.startsWith('packages/') ? family.split('/').last : family);
    for (final font in (f['fonts']! as List<Object?>).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}
