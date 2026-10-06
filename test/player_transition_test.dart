import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/widgets/app_transitions.dart';
import 'package:atlas_music/theme/app_theme.dart';

void main() {
  testWidgets('player transition snaps under reduce motion', (tester) async {
    late Widget built;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              built = buildPlayerTransition(
                context,
                const AlwaysStoppedAnimation<double>(0.5),
                const AlwaysStoppedAnimation<double>(0.0),
                const Text('player'),
              );
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(built, isA<Text>());
  });

  testWidgets('pushAppPage(slideUp: true) opens without exception',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pushAppPage(
              context,
              const Scaffold(body: Center(child: Text('full player'))),
              slideUp: true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('full player'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });
}
