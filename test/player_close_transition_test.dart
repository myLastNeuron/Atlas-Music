import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/widgets/app_transitions.dart';

// Regression: closing the full player only fades it out while the artwork
// flies back to the mini thumb. A collapsing surface around the page used to
// drag the header and the transport row up and down with the cover.
void main() {
  testWidgets('close fades the page and never moves it', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => pushAppPage(
                ctx,
                const Scaffold(
                  body: Center(child: Text('PLAYER', key: ValueKey('page'))),
                ),
                routeName: '/player',
                slideUp: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final page = find.byKey(const ValueKey('page'));
    final before = tester.getRect(page);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();

    var sawFade = false;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      if (page.evaluate().isEmpty) break;
      expect(tester.getRect(page), before,
          reason: 'page content moved while closing');
      final fade = tester.widget<FadeTransition>(
          find.ancestor(of: page, matching: find.byType(FadeTransition)).first);
      if (fade.opacity.value < 1.0) sawFade = true;
    }

    expect(sawFade, isTrue, reason: 'close must fade the page at all');
    await tester.pumpAndSettle();
    expect(find.text('PLAYER'), findsNothing);
  });
}
