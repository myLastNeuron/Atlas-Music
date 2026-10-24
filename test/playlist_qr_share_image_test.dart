import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:atlas_music/models/playlist.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/screens/playlist_qr_screen.dart';
import 'package:atlas_music/services/playlist_qr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zxing2/qrcode.dart';

Playlist playlistWith(int count) => Playlist(
      id: 'p1',
      name: 'Road Trip',
      songs: [
        for (var i = 0; i < count; i++)
          Song(
            id: 'vid$i',
            title: 'Track $i',
            artist: 'Artist $i',
            thumbnailUrl: '',
            duration: const Duration(seconds: 200),
            videoId: 'vid$i',
          ),
      ],
      createdAt: DateTime.now(),
    );

/// Renders the shared image exactly as the app does: through the same
/// off-screen capture the Share button uses.
Future<Uint8List> renderCard(
    WidgetTester tester, Playlist playlist, List<String> parts) async {
  late BuildContext hostContext;
  Uint8List? bytes;
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Builder(builder: (context) {
        hostContext = context;
        return TextButton(
          key: const ValueKey('capture'),
          onPressed: () async {
            bytes = await renderQrShareCardPng(
              hostContext,
              PlaylistQrShareCard(
                name: playlist.name,
                songCount: playlist.songs.length,
                parts: parts,
              ),
            );
          },
          child: const Text('capture'),
        );
      }),
    ),
  ));

  await tester.tap(find.byKey(const ValueKey('capture')));
  for (var i = 0; i < 20 && bytes == null; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  expect(bytes, isNotNull, reason: 'the off-screen card must be captured');
  return bytes!;
}

int pngWidth(Uint8List png) =>
    (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];

int pngHeight(Uint8List png) =>
    (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];

class _Gray {
  final int w, h;
  final Uint8List rgba;
  _Gray(this.w, this.h, this.rgba);

  bool dark(int x, int y) {
    final i = (y * w + x) * 4;
    return (rgba[i] + rgba[i + 1] + rgba[i + 2]) ~/ 3 < 128;
  }

  /// Bands of consecutive rows with at least [minDark] dark pixels. QR rows
  /// carry hundreds (half the row is dark); text rows only a few dozen.
  List<(int, int)> rowBands({int minDark = 1}) {
    final out = <(int, int)>[];
    int? from;
    for (var y = 0; y < h; y++) {
      var c = 0;
      for (var x = 0; x < w; x++) {
        if (dark(x, y)) c++;
      }
      final has = c >= minDark;
      if (has && from == null) from = y;
      if (!has && from != null) {
        out.add((from, y - 1));
        from = null;
      }
    }
    if (from != null) out.add((from, h - 1));
    return out;
  }

  /// Bands of consecutive columns holding dark pixels inside [y0]..[y1].
  List<(int, int)> colBands(int y0, int y1) {
    final out = <(int, int)>[];
    int? from;
    for (var x = 0; x < w; x++) {
      var has = false;
      for (var y = y0; y <= y1; y++) {
        if (dark(x, y)) {
          has = true;
          break;
        }
      }
      if (has && from == null) from = x;
      if (!has && from != null) {
        out.add((from, x - 1));
        from = null;
      }
    }
    if (from != null) out.add((from, w - 1));
    return out;
  }
}

/// Decodes every QR code on the sheet: finds the code band by rows, splits it
/// at the whitespace between codes, and reads each code separately the way a
/// camera reads one at a time.
Future<List<String>> decodeCodes(WidgetTester tester, Uint8List png) async {
  final codes = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final gray = _Gray(image.width, image.height, data!.buffer.asUint8List());

    String? read(int x0, int x1) {
      final cropW = x1 - x0;
      final pixels = Int32List(cropW * gray.h);
      for (var y = 0; y < gray.h; y++) {
        for (var x = 0; x < cropW; x++) {
          final i = (y * gray.w + x + x0) * 4;
          final r = gray.rgba[i];
          final g = gray.rgba[i + 1];
          final b = gray.rgba[i + 2];
          pixels[y * cropW + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
      }
      final source = RGBLuminanceSource(cropW, gray.h, pixels);
      final bitmap = BinaryBitmap(GlobalHistogramBinarizer(source));
      try {
        return QRCodeReader().decode(bitmap).text;
      } catch (_) {
        return null;
      }
    }

    // The tallest band of dark rows is where the QR codes live (text rows are
    // a few pixels tall).
    final rowBands = gray.rowBands(minDark: 120);
    rowBands.sort((a, b) => (b.$2 - b.$1).compareTo(a.$2 - a.$1));
    final band = rowBands.first;
    final colBands = gray.colBands(band.$1, band.$2);
    final found = <String>[];
    for (var i = 0; i < colBands.length; i++) {
      final x0 = i == 0 ? 0 : (colBands[i - 1].$2 + colBands[i].$1) ~/ 2;
      final x1 = i == colBands.length - 1
          ? gray.w
          : (colBands[i].$2 + colBands[i + 1].$1) ~/ 2;
      final value = read(x0, x1);

      if (value != null) found.add(value);
    }
    return found;
  });
  return codes ?? const [];
}

void main() {
  testWidgets('QR code in the shared image is readable and clones the playlist',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final playlist = playlistWith(20);
    final parts = PlaylistQrCodec.encode(playlist);
    final png = await renderCard(tester, playlist, parts);

    // PNG signature and size: 560 logical px at pixelRatio 2.5.
    expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(pngWidth(png), 1400);

    final codes = await decodeCodes(tester, png);
    expect(codes, hasLength(1), reason: 'one code carries this playlist');
    final decoded = codes.single;
    expect(decoded, startsWith('${PlaylistQrCodec.magic}:'));

    // The decoded code clones the playlist exactly.
    final assembler = PlaylistQrAssembler();
    expect(assembler.accept(decoded), isTrue);
    final payload = assembler.payload!;
    expect(payload.name, 'Road Trip');
    expect(payload.tracks, hasLength(20));
    expect(payload.tracks[7].title, 'Track 7');
    expect(payload.tracks[7].videoId, 'vid7');
  });

  testWidgets('every part of a long playlist is readable in the shared image',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final playlist = playlistWith(120);
    final parts = PlaylistQrCodec.encode(playlist);
    expect(parts.length, 2, reason: 'this fixture checks the two-code layout');

    final png = await renderCard(tester, playlist, parts);
    expect(pngHeight(png), greaterThan(600),
        reason: 'header, both QR parts and the footer must be in frame');

    final codes = await decodeCodes(tester, png);
    expect(codes, hasLength(2), reason: 'both parts must be scannable');
    expect(parts, containsAll(codes));

    // Both parts together rebuild the playlist.
    final assembler = PlaylistQrAssembler();
    assembler.accept(codes.first);
    expect(assembler.accept(codes.last), isTrue);
    expect(assembler.payload!.tracks, hasLength(120));
    expect(assembler.payload!.tracks.last.title, 'Track 119');
  });
}
