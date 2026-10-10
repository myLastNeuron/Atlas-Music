import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:atlas_music/models/video_stats.dart';
import 'package:atlas_music/widgets/video_stats_bar.dart';

void main() {
  group('VideoStats.formatCount', () {
    test('renders N/A for null and negative', () {
      expect(VideoStats.formatCount(null), 'N/A');
      expect(VideoStats.formatCount(-1), 'N/A');
      expect(VideoStats.formatCount(-12345), 'N/A');
    });

    test('keeps plain counts under 1000', () {
      expect(VideoStats.formatCount(0), '0');
      expect(VideoStats.formatCount(999), '999');
    });

    test('compact K/M/B, one decimal below 100', () {
      expect(VideoStats.formatCount(1000), '1K');
      expect(VideoStats.formatCount(1500), '1.5K');
      expect(VideoStats.formatCount(12000), '12K');
      expect(VideoStats.formatCount(123456), '123K');
      expect(VideoStats.formatCount(3400000), '3.4M');
      expect(VideoStats.formatCount(2500000000), '2.5B');
    });

    test('rounding rolls up to the next unit instead of "1000K"', () {
      expect(VideoStats.formatCount(999999), '1M');
    });
  });

  group('VideoStats', () {
    test('unavailable has no values and reports so', () {
      expect(VideoStats.unavailable.isUnavailable, isTrue);
      expect(VideoStats.unavailable.likes, isNull);
      expect(VideoStats.unavailable.dislikes, isNull);
    });

    test('missing fields stay null (never fabricated)', () {
      const stats = VideoStats(likes: 42);
      expect(stats.likes, 42);
      expect(stats.dislikes, isNull);
      expect(stats.isUnavailable, isFalse);
    });
  });

  group('VideoStatsBar', () {
    testWidgets('shows formatted likes and N/A for unavailable fields',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoStatsBar(
            videoId: 'abc12345678',
            fetch: (id) async => const VideoStats(likes: 1500),
          ),
        ),
      ));
      await tester.pump(); // let the fetch future complete

      expect(find.text('1.5K'), findsOneWidget);
      expect(find.text('N/A'), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_down_alt_outlined), findsOneWidget);
    });

    testWidgets('is strictly non-interactive', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoStatsBar(
            videoId: 'abc12345678',
            fetch: (id) async => const VideoStats(likes: 1),
          ),
        ),
      ));
      await tester.pump();

      final subtree = find.byType(VideoStatsBar);
      expect(
        find.descendant(of: subtree, matching: find.byType(IgnorePointer)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: subtree, matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(
        find.descendant(of: subtree, matching: find.byType(GestureDetector)),
        findsNothing,
      );
      expect(
        find.descendant(of: subtree, matching: find.byType(IconButton)),
        findsNothing,
      );

      // A tap on a stat changes nothing and throws nothing (the row ignores
      // pointers, so the tap misses the icon on purpose).
      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined),
          warnIfMissed: false);
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
    });
  });
}
