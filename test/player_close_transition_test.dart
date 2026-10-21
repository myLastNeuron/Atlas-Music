import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/widgets/app_transitions.dart';

// Regression: the player close must travel DOWN only. If the slide tween is
// inverted the page starts below and rises, which reads as the player
// flashing back after it was closed.
void main() {
  testWidgets('close slides down monotonically and never rises',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => pushAppPage(
                ctx,
                const Scaffold(body: Center(child: Text('PLAYER'))),
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
    final openY = tester.getTopLeft(find.text('PLAYER')).dy;

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();

    double? previous;
    final samples = <double>[];
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      if (find.text('PLAYER').evaluate().isEmpty) break;
      final y = tester.getTopLeft(find.text('PLAYER')).dy;
      samples.add(y);
      if (previous != null) {
        expect(y, greaterThanOrEqualTo(previous - 1),
            reason: 'page moved back up: $samples');
      }
      previous = y;
    }

    expect(samples, isNotEmpty);
    expect(samples.first, greaterThan(openY),
        reason: 'close must start by moving down: $samples');
    expect(samples.first, lessThan(openY + 250),
        reason: 'close must not jump to the bottom: $samples');
    await tester.pumpAndSettle();
    expect(find.text('PLAYER'), findsNothing);
  });
}
