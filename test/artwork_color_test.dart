import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/services/artwork_color.dart';

/// [count] copies of one RGBA pixel.
Uint8List _pixels(int count, List<int> rgba) {
  final data = Uint8List(count * 4);
  for (var i = 0; i < count; i++) {
    data.setRange(i * 4, i * 4 + 4, rgba);
  }
  return data;
}

void main() {
  test('picks the cover colour over a black frame', () {
    final pixels = Uint8List.fromList([
      ..._pixels(60, [20, 30, 200, 255]),
      ..._pixels(40, [0, 0, 0, 255]),
    ]);
    final color = dominantColorOfPixels(pixels)!;
    // Color channels are 0..1 since 3.27; the bytes are what we assert on.
    expect((color.b * 255).round(), closeTo(200, 8));
    expect((color.r * 255).round(), closeTo(20, 8));
  });

  test('a monochrome cover falls back to its average', () {
    final pixels = Uint8List.fromList([
      ..._pixels(50, [255, 255, 255, 255]),
      ..._pixels(50, [0, 0, 0, 255]),
    ]);
    final color = dominantColorOfPixels(pixels)!;
    expect((color.r * 255).round(), inInclusiveRange(120, 135));
    expect((color.g * 255).round(), inInclusiveRange(120, 135));
  });

  test('transparent pixels are ignored', () {
    final pixels = Uint8List.fromList([
      ..._pixels(90, [0, 0, 0, 0]),
      ..._pixels(10, [220, 40, 40, 255]),
    ]);
    final color = dominantColorOfPixels(pixels)!;
    expect(color.r, greaterThan(color.g));
  });

  test('no opaque pixel means no colour', () {
    expect(dominantColorOfPixels(Uint8List(0)), isNull);
    expect(dominantColorOfPixels(Uint8List.fromList([0, 0, 0, 0])), isNull);
  });

  testWidgets('a cover\'s colour is read once, then served from the cache',
      (tester) async {
    // The player asks for the same cover's colour on every open. With the
    // colour remembered, a repeated open can paint its tint on the first frame
    // instead of decoding again and re-rasterising the page after the flight.
    debugClearArtworkColorCache();
    addTearDown(debugClearArtworkColorCache);

    late File file;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 16, 16),
        Paint()..color = const Color(0xFF2050A0),
      );
      final image = await recorder.endRecording().toImage(16, 16);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = await Directory.systemTemp.createTemp('artwork_color');
      file = File('${dir.path}/cover.png')
        ..writeAsBytesSync(data!.buffer.asUint8List());
    });

    // The decode is real engine/IO work: let the real event loop run it.
    final first = await tester.runAsync(
        () => dominantArtworkColor('', filePath: file.path));
    expect(first, isNotNull);
    expect(cachedArtworkColor('', filePath: file.path), first,
        reason: 'the player can paint the tint without waiting');

    // Read from memory, not from the file: the second read still answers after
    // the cover is gone.
    file.deleteSync();
    expect(await dominantArtworkColor('', filePath: file.path), first);
  });
}
