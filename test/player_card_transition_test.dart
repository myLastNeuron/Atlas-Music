import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/theme/app_theme.dart';
import 'package:atlas_music/widgets/app_transitions.dart';

// Regression: the card around the full player grows; the page inside it does
// not. The page is laid out once at the window's size and clipped by the card,
// so its render box never resizes mid-flight — that is what keeps the cover and
// the glass from being re-rasterised every frame. And the card grows over the
// app: the route below stays mounted and painted under it.
void main() {
  testWidgets('the card grows around a page that is built and sized once',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const bar = Rect.fromLTRB(16, 700, 384, 770);
    playerCardFrom = bar;
    addTearDown(() => playerCardFrom = null);

    var builds = 0;
    final page = Scaffold(
      key: const ValueKey('page'),
      body: _BuildCounter(onBuild: () => builds++),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        key: const ValueKey('home'),
        body: Center(
          child: Builder(
            builder: (ctx) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => pushAppPage(ctx, page, slideUp: true),
                  child: const Text('open'),
                ),
                // A stand-in mini bar: the home screen the card grows out of.
                const SizedBox(
                  key: ValueKey('bar'),
                  width: 300,
                  height: 60,
                  child: ColoredBox(color: Colors.blue),
                ),
              ],
            ),
          ),
        ),
      ),
    ));

    final card = find.byKey(const ValueKey('player_sheet'));
    final pageFinder = find.byKey(const ValueKey('page'));

    await tester.tap(find.text('open'));
    // The pushed route builds on the frame after the tap; both pumps are at
    // zero elapsed, so the card has not moved yet.
    await tester.pump();
    await tester.pump();

    // First frame: the card is the bar's rectangle, and the page inside it is
    // already the full window — clipped by the card, not shrunk to it.
    final pageStart = tester.getSize(pageFinder);
    expect(pageStart, const Size(400, 800));
    expect(tester.getRect(card).width, closeTo(bar.width, 0.5));
    expect(builds, 1);

    // Frame by frame to the half-way point: the card is bigger than the bar,
    // and the page has neither rebuilt nor resized.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 15));
    }
    expect(builds, 1);
    expect(tester.getSize(pageFinder), pageStart);
    expect(tester.getRect(card).width, greaterThan(bar.width));
    // The home screen below is still mounted and painted while the card is over
    // it: the bar the card grows out of does not dissolve under the card.
    expect(find.byKey(const ValueKey('home')), findsOneWidget);
    expect(find.byKey(const ValueKey('home'), skipOffstage: false),
        findsOneWidget);
    expect(find.byKey(const ValueKey('bar')), findsOneWidget);

    // On to the end of the card trip.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 15));
    }
    // Last frame: the card is the window, and the page is still exactly the
    // size it started at — the card grew, the page never did.
    expect(tester.getRect(card), const Rect.fromLTWH(0, 0, 400, 800));
    expect(tester.getSize(pageFinder), pageStart);
    expect(builds, 1);
    expect(tester.takeException(), isNull);

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
