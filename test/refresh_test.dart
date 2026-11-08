import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/widgets/app_transitions.dart';
import 'package:atlas_music/widgets/skeleton_card.dart';

void main() {
  testWidgets('an instant reload keeps the indicator up for the minimum',
      (tester) async {
    var done = false;
    minRefresh(() async {}).then((_) => done = true);

    await tester.pump(const Duration(milliseconds: 699));
    expect(done, isFalse);

    await tester.pump(const Duration(milliseconds: 1));
    expect(done, isTrue);
  });

  testWidgets('a slow reload is not held any longer', (tester) async {
    final reload = Completer<void>();
    var done = false;
    minRefresh(() => reload.future).then((_) => done = true);

    await tester.pump(const Duration(seconds: 5));
    expect(done, isFalse);

    reload.complete();
    await tester.pump();
    expect(done, isTrue);
  });

  testWidgets('a failing reload still propagates its error', (tester) async {
    Object? error;
    minRefresh(() async => throw StateError('offline')).catchError((Object e) {
      error = e;
    });

    await tester.pump(const Duration(milliseconds: 700));
    expect(error, isA<StateError>());
  });

  testWidgets('pull keeps the spinner on screen for the whole hold',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RefreshIndicator(
          onRefresh: () => minRefresh(() async {}),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics()),
            itemCount: 30,
            itemBuilder: (_, i) => SizedBox(height: 60, child: Text('$i')),
          ),
        ),
      ),
    ));

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RefreshProgressIndicator), findsWidgets);

    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('pull swaps the list for skeletons until the reload finishes',
      (tester) async {
    final reload = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RefreshSkeleton(
          onRefresh: () => reload.future,
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics()),
            itemCount: 3,
            itemBuilder: (_, i) => Text('row $i'),
          ),
        ),
      ),
    ));

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SkeletonListItem), findsWidgets);
    expect(find.text('row 0'), findsNothing);

    reload.complete();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    expect(find.byType(SkeletonListItem), findsNothing);
    expect(find.text('row 0'), findsOneWidget);
  });

  testWidgets('a page can supply its own skeleton shape', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RefreshSkeleton(
          onRefresh: () async {},
          skeleton: const Text('page skeleton'),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics()),
            itemCount: 3,
            itemBuilder: (_, i) => Text('row $i'),
          ),
        ),
      ),
    ));

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('page skeleton'), findsOneWidget);
    expect(find.text('row 0'), findsNothing);

    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(find.text('page skeleton'), findsNothing);
  });
}
