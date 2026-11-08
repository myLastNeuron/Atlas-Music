import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/screens/player_screen.dart';

// Regression: tapping the mini bar while the full player is closing used to
// empty the navigator (black screen). The player route is already gone from
// the navigator during its reverse transition, so the pop guard must also
// stop at the first route.

PageRouteBuilder<void> _route(String name, String label) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, __, ___) =>
          Scaffold(body: Center(child: Text(label))),
      transitionDuration: const Duration(milliseconds: 700),
      reverseTransitionDuration: const Duration(milliseconds: 700),
    );

void main() {
  testWidgets('popUntil mid-close never empties the navigator',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: Text('home'))),
    ));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));

    nav.push(_route(PlayerScreen.routeName, 'player'));
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);

    // The close has started: the route is popping, so it is no longer
    // present even though its widget (and PlayerScreen.isOpen) still is.
    nav.pop();
    await tester.pump(const Duration(milliseconds: 100));
    nav.popUntil(isPlayerRouteOrFirst);
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget,
        reason: 'the first route must survive the guard');
    expect(find.text('player'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a player below the artist page is still the pop target',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: Text('home'))),
    ));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));

    nav.push(_route(PlayerScreen.routeName, 'player'));
    await tester.pumpAndSettle();
    nav.push(_route('/artist', 'artist'));
    await tester.pumpAndSettle();

    nav.popUntil(isPlayerRouteOrFirst);
    await tester.pumpAndSettle();

    expect(find.text('artist'), findsNothing);
    expect(find.text('player'), findsOneWidget);
    // The player is opaque, so the first route below it is offstage.
    expect(find.text('home', skipOffstage: false), findsOneWidget);
  });
}
