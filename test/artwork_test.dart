import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/widgets/artwork.dart';

Future<void> _pump(WidgetTester tester, Artwork art) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: art)),
    ),
  );
}

/// A real PNG on disk, so the decode path runs for real.
Future<File> _coverFile(WidgetTester tester) async {
  late File file;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 16, 16),
      Paint()..color = const Color(0xFF3060A0),
    );
    final image = await recorder.endRecording().toImage(16, 16);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = await Directory.systemTemp.createTemp('artwork_decode');
    file = File('${dir.path}/cover.png')
      ..writeAsBytesSync(data!.buffer.asUint8List());
  });
  return file;
}

Size _fallbackSize(WidgetTester tester) {
  final icon = find.byIcon(Icons.music_note);
  expect(icon, findsOneWidget);
  final box = find.ancestor(of: icon, matching: find.byType(Container)).first;
  return tester.getSize(box);
}

void main() {
  testWidgets('square size honored', (tester) async {
    await _pump(tester, const Artwork('', size: 140));
    expect(_fallbackSize(tester), const Size(140, 140));
  });

  testWidgets('explicit width+height box honored', (tester) async {
    await _pump(tester, const Artwork('', width: 150, height: 130, radius: 0));
    expect(_fallbackSize(tester), const Size(150, 130));
  });

  testWidgets('square art fits 360px phone player slot', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    // Player slot: screen - 80 (page padding) - 24 (panel padding).
    const slot = 360.0 - 104;
    await _pump(tester, const Artwork('', size: slot));
    expect(_fallbackSize(tester).width, lessThanOrEqualTo(360.0 - 80));
  });

  testWidgets('large art crops to fill with a single decode', (tester) async {
    // Closed-port URL fails fast: structure asserts need no settle.
    // Perf: one CachedNetworkImage (cover) over cheap mist fill —
    // prior double-stack decoded same URL twice per large card.
    await _pump(tester, const Artwork('http://127.0.0.1:9/x.jpg', size: 140));
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    final img =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(img.fit, BoxFit.cover);
  });

  testWidgets('tiny art stays single cover layer', (tester) async {
    await _pump(tester, const Artwork('http://127.0.0.1:9/x.jpg', size: 42));
    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });

  testWidgets('decodeWidth keeps one decode when the box changes size',
      (tester) async {
    final file = await _coverFile(tester);
    addTearDown(() => file.deleteSync());
    final cache = PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();

    // The player's cover: the box is whatever the fixed rows leave over, the
    // decode is always the flight's bitmap size.
    await _pump(
        tester, Artwork('', filePath: file.path, size: 100, decodeWidth: 200));
    await _settle(tester);
    final decoded = cache.currentSize;
    expect(decoded, greaterThan(0), reason: 'the cover decoded');

    await _pump(
        tester, Artwork('', filePath: file.path, size: 300, decodeWidth: 200));
    await _settle(tester);
    expect(cache.currentSize, decoded,
        reason: 'a bigger box rescales the same bitmap, no second decode');

    // Without it the box is the cache key: the up-next peek landing would
    // decode the artwork again, which is the blink this guards against.
    await _pump(tester, Artwork('', filePath: file.path, size: 100));
    await _settle(tester);
    await _pump(tester, Artwork('', filePath: file.path, size: 300));
    await _settle(tester);
    expect(cache.currentSize, greaterThan(decoded));
  });
}

/// Lets the real event loop finish the decode: image loading is real async
/// work, and the test's fake clock never runs it.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 6; round++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}
