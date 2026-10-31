// SPDX-License-Identifier: AGPL-3.0-only
// PNG pictures for tests: drawn by the engine, optionally with a text chunk (metadata a preview must not keep), and
// the size of an encoded picture as the engine decodes it.

import 'dart:io' show ZLibCodec;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// A [w] × [h] PNG drawn by the engine (two colours, so it is not empty), with a `tEXt` chunk `key=value` right after
/// its header: what a camera or a screenshot tool writes into a file.
Future<Uint8List> pngWithText(int w, int h, String key, String value) async {
  final rec = ui.PictureRecorder();
  Canvas(rec)
    ..drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF1560F6))
    ..drawRect(Rect.fromLTWH(0, 0, w / 2, h / 2), Paint()..color = const Color(0xFFFFFFFF));
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  final data = (await img.toByteData(format: ui.ImageByteFormat.png))!;
  img.dispose();
  final png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  // Signature (8) + IHDR (4 length + 4 type + 13 data + 4 CRC) = 33 bytes; the text chunk goes right after.
  final text = Uint8List.fromList([...key.codeUnits, 0, ...value.codeUnits]);
  return Uint8List.fromList([...png.sublist(0, 33), ..._chunk('tEXt', text), ...png.sublist(33)]);
}

/// A [w] × [h] PNG of one colour [rgb] (0xRRGGBB), made here in plain Dart: no engine, so no `runAsync` to build it.
Uint8List plainPng(int w, int h, {int rgb = 0x3949AB}) {
  final row = Uint8List(1 + w * 3);
  for (var x = 0; x < w; x++) {
    row
      ..[1 + x * 3] = (rgb >> 16) & 0xFF
      ..[2 + x * 3] = (rgb >> 8) & 0xFF
      ..[3 + x * 3] = rgb & 0xFF;
  }
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < h; y++) {
    raw.add(row);
  }
  final ihdr = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2); // RGB
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ..._chunk('IHDR', ihdr.buffer.asUint8List()),
    ..._chunk('IDAT', Uint8List.fromList(ZLibCodec().encode(raw.takeBytes()))),
    ..._chunk('IEND', Uint8List(0)),
  ]);
}

/// The width and height the engine decodes [png] at.
Future<(int, int)> pngSize(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = (await codec.getNextFrame()).image;
  final size = (frame.width, frame.height);
  frame.dispose();
  codec.dispose();
  return size;
}

List<int> _chunk(String type, Uint8List data) {
  final body = [...type.codeUnits, ...data];
  final len = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32(body));
  return [...len.buffer.asUint8List(), ...body, ...crc.buffer.asUint8List()];
}

/// The CRC-32 a PNG chunk carries (ISO 3309): a checksum of the file format, not cryptography.
int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}
