import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/theme/app_theme.dart';
import 'package:atlas_music/widgets/mode_slider.dart';

/// The three stops must map to the three palettes; the slider is discrete, so
/// a tap anywhere in a third of the track selects that third's mode.
void main() {
  testWidgets('tapping each stop reports its mode', (tester) async {
    AppPalette? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: ModeSlider(
                mode: AppPalette.grey,
                onChanged: (m) => picked = m,
              ),
            ),
          ),
        ),
      ),
    );

    final rect = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(rect.left + 40, rect.center.dy));
    await tester.pump();
    expect(picked, AppPalette.light);

    picked = null;
    await tester.tapAt(Offset(rect.right - 40, rect.center.dy));
    await tester.pump();
    expect(picked, AppPalette.amoled);
  });
}
