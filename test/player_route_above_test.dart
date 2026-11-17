import 'package:atlas_music/app.dart';
import 'package:atlas_music/screens/player_screen.dart';
import 'package:atlas_music/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Regression: the observer used to leave [playerRouteAbove] true after a
// completed player pop, because a popped route is disposed without emitting
// didRemove. Normal page transitions then stayed disabled for the rest of the
// session. The flag must only be true while the player really sits above the
// route that is animating.
Route<void> _route(String name, String label,
        {Duration duration = const Duration(milliseconds: 300)}) =>
    _TestRoute(
      name: name,
      label: label,
      duration: duration,
    );

/// A route whose transition controller is reachable from the test, so a pop
/// can be cancelled midway the way a dismissed back gesture would.
class _TestRoute extends PageRouteBuilder<void> {
  _TestRoute({
    required String name,
    required String label,
    required Duration duration,
  }) : super(
          settings: RouteSettings(name: name),
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          pageBuilder: (_, __, ___) =>
              Scaffold(body: Center(child: Text(label))),
        );

  AnimationController get testController => super.controller!;
}

Future<NavigatorState> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: [buildPlayerRouteObserver()],
    home: const Scaffold(body: Center(child: Text('home'))),
  ));
  return tester.state<NavigatorState>(find.byType(Navigator));
}

void main() {
  // The flag is global; never let one test's state leak into the next.
  tearDown(() => playerRouteAbove = false);

  testWidgets('a completed player close clears playerRouteAbove',
      (tester) async {
    final nav = await _pumpApp(tester);

    nav.push(_route(PlayerScreen.routeName, 'player'));
    await tester.pumpAndSettle();
    expect(playerRouteAbove, isTrue,
        reason: 'the player is above the page while it is open');

    nav.pop();
    await tester.pump();
    expect(playerRouteAbove, isTrue,
        reason: 'the card is still shrinking back into the bar');

    await tester.pumpAndSettle();
    expect(playerRouteAbove, isFalse,
        reason: 'the player route is gone, normal pages may animate again');
  });

  testWidgets('a cancelled player close keeps playerRouteAbove set',
      (tester) async {
    final nav = await _pumpApp(tester);
    final route = _TestRoute(
      name: PlayerScreen.routeName,
      label: 'player',
      duration: const Duration(milliseconds: 300),
    );

    nav.push(route);
    await tester.pumpAndSettle();
    expect(playerRouteAbove, isTrue);

    nav.pop();
    await tester.pump(const Duration(milliseconds: 100));
    expect(route.testController.status, AnimationStatus.reverse);
    expect(playerRouteAbove, isTrue);

    // The back gesture was cancelled: the route runs forward again and stays
    // on screen, so the page below must still be held still.
    route.testController.forward();
    await tester.pumpAndSettle();
    expect(route.testController.status, AnimationStatus.completed);
    expect(playerRouteAbove, isTrue,
        reason: 'a cancelled close is not a completed close');
  });

  testWidgets('ordinary routes never leave playerRouteAbove set',
      (tester) async {
    final nav = await _pumpApp(tester);

    // A page pushed and popped without a player never sets the flag.
    nav.push(_route('/detail', 'detail'));
    await tester.pumpAndSettle();
    expect(playerRouteAbove, isFalse);
    nav.pop();
    await tester.pumpAndSettle();
    expect(playerRouteAbove, isFalse);

    // And after a real player open/close, a later ordinary route still
    // animates normally (the bug left the flag stuck true).
    nav.push(_route(PlayerScreen.routeName, 'player'));
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    expect(playerRouteAbove, isFalse);

    nav.push(_route('/detail', 'detail'));
    await tester.pumpAndSettle();
    expect(playerRouteAbove, isFalse);
    nav.pop();
    await tester.pumpAndSettle();
    expect(playerRouteAbove, isFalse);
  });
}
