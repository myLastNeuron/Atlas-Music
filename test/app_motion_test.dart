import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/widgets/app_transitions.dart';

void main() {
  testWidgets('press response repels from the touch and preserves taps',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MotionPress(
              child: GestureDetector(
                onTap: () => tapped = true,
                child: Container(
                  width: 100,
                  height: 100,
                  color: Colors.transparent,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final bounds = tester.getRect(find.byType(MotionPress));
    final gesture =
        await tester.startGesture(bounds.topLeft + const Offset(8, 8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final transforms = tester.widgetList<Transform>(
      find.descendant(
        of: find.byType(MotionPress),
        matching: find.byType(Transform),
      ),
    );
    expect(
      transforms.any((transform) =>
          transform.transform.getTranslation().x > 0 &&
          transform.transform.getTranslation().y > 0),
      isTrue,
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
    final resetTransforms = tester.widgetList<Transform>(
      find.descendant(
        of: find.byType(MotionPress),
        matching: find.byType(Transform),
      ),
    );
    expect(
      resetTransforms.every((transform) =>
          transform.transform.getTranslation().x == 0 &&
          transform.transform.getTranslation().y == 0),
      isTrue,
    );
  });
}
