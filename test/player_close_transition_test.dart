import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/theme/app_theme.dart';
import 'package:atlas_music/widgets/app_transitions.dart';

// Regression: the full player is a card that grows out of the mini bar. The
// card's own rectangle morphs from the bar's rect to the window's and back:
// the bar's top edge sweeps up, its bottom edge down and its width out to the
// window's, so the player submerges the screen from the bar instead of a sheet
// appearing above it.
//
// Geometry is measured on the card's clip (`player_sheet`): the page inside it
// is window-sized and clipped to the card, so the card is what must land on
// the bar.
void main() {
  testWidgets('the player card grows out of the bar and collapses back into it',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const bar = Rect.fromLTRB(16, 700, 384, 770);
    playerCardFrom = bar;
    addTearDown(() => playerCardFrom = null);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => pushAppPage(
                ctx,
                const Scaffold(
                  body: SizedBox.expand(key: ValueKey('page')),
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

    final card = find.byKey(const ValueKey('player_sheet'));
    expect(card, findsNothing);

    await tester.tap(find.text('open'));
    // The pushed route builds on the frame after the tap; both pumps are at
    // zero elapsed, so this is still frame zero of the trip.
    await tester.pump();
    await tester.pump();
    // Frame zero: the card is exactly the bar it grows out of.
    _expectCard(tester.getRect(card), bar);

    // One frame per 15 ms, sampled every frame so a jump (a resize, a hard
    // cut) cannot hide between frames. The trip length comes from the motion
    // constant, not a hard-coded 360.
    const step = Duration(milliseconds: 15);
    final openSteps = AppMotion.playerOpen.inMilliseconds ~/ 15;
    final open = <Rect>[tester.getRect(card)];
    for (var i = 0; i < openSteps; i++) {
      await tester.pump(step);
      open.add(tester.getRect(card));
      expect(tester.takeException(), isNull);
    }
    // The last few milliseconds of the trip.
    await tester.pump(AppMotion.playerOpen - step * openSteps);
    open.add(tester.getRect(card));

    // The bar's edges morph into the player's edges: the top only rises, the
    // bottom only falls, the sides only spread. Nothing snaps.
    for (var i = 1; i < open.length; i++) {
      expect(open[i].top, lessThanOrEqualTo(open[i - 1].top + 0.01));
      expect(open[i].left, lessThanOrEqualTo(open[i - 1].left + 0.01));
      expect(open[i].right, greaterThanOrEqualTo(open[i - 1].right - 0.01));
      expect(open[i].bottom, greaterThanOrEqualTo(open[i - 1].bottom - 0.01));
    }
    // Halfway through the morph the card is between the two, not already the
    // window with the bar's edges cut away.
    final mid = open[open.length ~/ 2];
    expect(mid.top, greaterThan(0));
    expect(mid.top, lessThan(bar.top));
    expect(mid.width, greaterThan(bar.width));
    expect(mid.width, lessThan(400));
    // And it ends as the whole window.
    _expectCard(open.last, const Rect.fromLTWH(0, 0, 400, 800));

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    _expectCard(tester.getRect(card), const Rect.fromLTWH(0, 0, 400, 800));

    final close = <Rect>[tester.getRect(card)];
    for (var i = 0; i < openSteps; i++) {
      await tester.pump(step);
      close.add(tester.getRect(card));
      expect(tester.takeException(), isNull);
    }
    // One millisecond before the route is removed: the card is back on the
    // bar's rectangle, so the player settles into the bar instead of
    // vanishing.
    await tester.pump(AppMotion.playerClose -
        step * openSteps -
        const Duration(milliseconds: 1));
    close.add(tester.getRect(card));
    _expectCard(close.last, bar, eps: 0.5);

    // The close is the same trip in reverse: every edge walks back.
    for (var i = 1; i < close.length; i++) {
      expect(close[i].top, greaterThanOrEqualTo(close[i - 1].top - 0.01));
      expect(close[i].left, greaterThanOrEqualTo(close[i - 1].left - 0.01));
      expect(close[i].right, lessThanOrEqualTo(close[i - 1].right + 0.01));
      expect(close[i].bottom, lessThanOrEqualTo(close[i - 1].bottom + 0.01));
    }
    expect(close.last.width, lessThan(close.first.width));

    // The last millisecond lands on the bar and removes the route.
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(find.byKey(const ValueKey('page')), findsNothing);
  });
}

/// Asserts a card rect's four edges, each within [eps] of [expected].
void _expectCard(Rect actual, Rect expected, {double eps = 0.01}) {
  expect(actual.left, closeTo(expected.left, eps));
  expect(actual.top, closeTo(expected.top, eps));
  expect(actual.right, closeTo(expected.right, eps));
  expect(actual.bottom, closeTo(expected.bottom, eps));
}
