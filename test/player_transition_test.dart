import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/widgets/app_transitions.dart';
import 'package:atlas_music/theme/app_theme.dart';

void main() {
  // Open and close share one flight duration so both directions feel the same.
  test('player transitions stay symmetric and short', () {
    expect(AppMotion.playerOpen, AppMotion.playerClose);
    expect(AppMotion.playerOpen.inMilliseconds, lessThanOrEqualTo(500));
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

  testWidgets('the cover Hero flies from the bar into the player',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              const SizedBox(
                width: 64,
                height: 64,
                child: Hero(
                  tag: 'cover',
                  child: SizedBox.expand(key: ValueKey('src')),
                ),
              ),
              TextButton(
                onPressed: () => pushAppPage(
                  context,
                  const Scaffold(
                    body: Hero(
                      tag: 'cover',
                      child: SizedBox.expand(key: ValueKey('dst')),
                    ),
                  ),
                  slideUp: true,
                ),
                child: const Text('open'),
              ),
            ],
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pump();
    // Half of AppMotion.playerOpen: the shuttle is in the air. While it flies,
    // both landing spots hold placeholders, so the only `dst` in the tree is
    // the shuttle Flutter parks in the Navigator overlay at the interpolated
    // rect. Its box is between the 64 px thumb and the full-width cover: the
    // cover morphs instead of appearing already big.
    await tester.pump(AppMotion.playerOpen ~/ 2);
    final shuttle = find.byKey(const ValueKey('dst'));
    expect(shuttle, findsOneWidget);
    expect(find.descendant(of: find.byType(Overlay), matching: shuttle),
        findsOneWidget);
    final mid = tester.getRect(shuttle);
    expect(mid.width, greaterThan(64));
    expect(mid.width, lessThan(400));
    // The home route is still mounted beneath the player: only the source
    // cover itself is swapped for a placeholder while the shuttle flies, so
    // the rest of the bar (here its button) is still there.
    expect(find.text('open'), findsOneWidget);
    expect(find.byKey(const ValueKey('src')), findsNothing);

    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('dst'))),
        const Rect.fromLTWH(0, 0, 400, 800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page is built once per flight, not per animation frame',
      (tester) async {
    var builds = 0;
    final page = Scaffold(body: _BuildCounter(onBuild: () => builds++));

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pushAppPage(context, page, slideUp: true),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    // Frame by frame through the whole open: the card grows, the fades ramp
    // and the corners unfurl, all render-object work. A page rebuild here
    // would repaint the cover, the glass and the transport every frame.
    for (var i = 0; i <= 28; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(builds, 1);

    await tester.pumpAndSettle();
  });
}

/// Counts how often the transition lets the page subtree build.
class _BuildCounter extends StatelessWidget {
  final void Function() onBuild;
  const _BuildCounter({required this.onBuild});

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox.shrink();
  }
}
