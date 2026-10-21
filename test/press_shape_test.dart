import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/theme/app_theme.dart';
import 'package:atlas_music/widgets/liquid_background.dart';

/// A press paints its highlight on the nearest Material and clips it to that
/// Material's shape. Glass surfaces must therefore be shaped Materials, and
/// rows must carry a rounded shape, or a held button lights up as a sharp
/// rectangle that does not match the surface.
void main() {
  testWidgets('a held row lights up inside the panel, never over its corner',
      (tester) async {
    const panelKey = ValueKey('panel');
    await tester.pumpWidget(
      MaterialApp(
        // A plain theme with the app's row shape: the app theme itself pulls a
        // Google webfont, and the failed download would land in this test.
        theme: ThemeData.dark().copyWith(
          listTileTheme: const ListTileThemeData(shape: kRowPressShape),
        ),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: RepaintBoundary(
              key: panelKey,
              child: SizedBox(
                width: 200,
                height: 100,
                child: GlassPanel(
                  radius: 20,
                  child: ListTile(title: const Text('Row'), onTap: () {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    Future<int> brightnessAt(int x, int y) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(panelKey),
      );
      // toImage() waits on the raster thread, which the fake test clock never
      // advances -> capture it in the real async zone.
      final image = await tester.runAsync(() => boundary.toImage());
      final data = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
      final i = (y * image!.width + x) * 4;
      return data!.getUint8(i) + data.getUint8(i + 1) + data.getUint8(i + 2);
    }

    final beforeRow = await brightnessAt(30, 50);
    final beforeCorner = await brightnessAt(2, 2);

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('Row')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The row itself is highlighted ...
    expect(await brightnessAt(30, 50), greaterThan(beforeRow));
    // ... and the panel's rounded corner stays untouched.
    expect(await brightnessAt(2, 2), beforeCorner);

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
