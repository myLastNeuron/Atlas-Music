import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/widgets/app_transitions.dart';
import 'package:atlas_music/widgets/floating_glass_nav.dart';
import 'package:atlas_music/widgets/liquid_background.dart';

void main() {
  testWidgets('ambient background stays still under reduce motion',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: LiquidBackground(child: SizedBox()),
        ),
      ),
    );
    // If the ambient loop ignored reduce motion this would never settle.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('FadeSlideIn renders immediately under reduce motion',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: FadeSlideIn(child: Text('instant')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('instant'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stagger renders its child', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Stagger(index: 2, child: Text('staggered')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('staggered'), findsOneWidget);
  });

  testWidgets('glass nav pill sits centred under the active tab',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: FloatingGlassNav(
            currentIndex: 2,
            onTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pill = tester.getRect(find.byKey(const ValueKey('nav_pill')));
    final tab = tester.getRect(find.byKey(const ValueKey('nav_2')));
    expect((pill.center.dx - tab.center.dx).abs(), lessThan(1.0));
  });
}
