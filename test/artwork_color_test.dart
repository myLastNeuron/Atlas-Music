import 'dart:typed_data';

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
}
