import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/artwork_color.dart';
import 'package:atlas_music/services/audio_service.dart';
import 'package:atlas_music/services/theme_settings.dart';
import 'package:atlas_music/widgets/sleep_timer_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugClearArtworkColorCache();
  });

  Future<_FakeAudio> openSheet(WidgetTester tester,
      {_FakeAudio? fake, ThemeSettings? theme}) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final audio = fake ?? _FakeAudio();
    await tester.pumpWidget(ChangeNotifierProvider<ThemeSettings>.value(
      value: theme ?? ThemeSettings(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSleepTimerSheet(context, audio),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return audio;
  }

  testWidgets('a preset starts the sleep timer and the clock shows 45 min',
      (tester) async {
    final audio = await openSheet(tester);

    expect(find.text('Sleep Timer'), findsOneWidget);
    expect(find.text('15 min'), findsOneWidget);
    expect(find.text('45 min'), findsOneWidget);
    expect(find.text('60 min'), findsOneWidget);
    expect(find.textContaining('New timer ends at'), findsOneWidget);

    await tester.tap(find.text('45 min'));
    await tester.pump();
    expect(find.textContaining('45'), findsWidgets);

    await tester.tap(find.text('Start Timer'));
    await tester.pumpAndSettle();
    expect(audio.timer, const Duration(minutes: 45));
  });

  testWidgets('a custom duration starts the typed timer', (tester) async {
    final audio = await openSheet(tester);

    await tester.tap(find.text('Custom Duration'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '20');
    await tester.pump();

    await tester.tap(find.text('Start Timer'));
    await tester.pumpAndSettle();
    expect(audio.timer, const Duration(minutes: 20));
  });

  testWidgets('a running timer shows its real deadline and can be turned off',
      (tester) async {
    final audio = _FakeAudio()
      ..deadline = DateTime.now().add(const Duration(minutes: 12));
    await openSheet(tester, fake: audio);

    expect(find.textContaining('Ends at'), findsOneWidget);
    expect(find.text('Turn off sleep timer'), findsOneWidget);
  });

  testWidgets('a finished timer opens as a new-timer preview', (tester) async {
    final audio = _FakeAudio()
      ..pending = true
      ..finished = true
      ..lastDuration = const Duration(minutes: 45);
    await openSheet(tester, fake: audio);

    expect(find.textContaining('New timer ends at'), findsOneWidget);
    expect(find.text('Turn off sleep timer'), findsNothing);
    expect(find.textContaining('45'), findsWidgets);
  });

  testWidgets('the sheet follows the current song tint while open',
      (tester) async {
    const blue = Color(0xFF3366FF);
    const green = Color(0xFF33AA55);
    final a = Song(
      id: 'a',
      title: 'A',
      artist: 'X',
      thumbnailUrl: 'https://example.com/a.jpg',
      duration: const Duration(minutes: 3),
    );
    final b = Song(
      id: 'b',
      title: 'B',
      artist: 'X',
      thumbnailUrl: 'https://example.com/b.jpg',
      duration: const Duration(minutes: 3),
    );
    debugSeedArtworkColor(a.thumbnailUrl, blue);
    debugSeedArtworkColor(b.thumbnailUrl, green);

    final theme = ThemeSettings();
    await theme.setArtworkColor(true);
    final audio = _FakeAudio()..song = a;
    await openSheet(tester, fake: audio, theme: theme);

    Color? buttonColor() => tester
        .widget<FilledButton>(find.byType(FilledButton))
        .style
        ?.backgroundColor
        ?.resolve(<WidgetState>{});
    expect(buttonColor(), blue);

    audio.song = b;
    audio.notifyListeners();
    await tester.pump();
    expect(buttonColor(), green);

    await theme.setArtworkColor(false);
    await tester.pump();
    expect(buttonColor(), isNot(green));
  });
}

/// Only the surface the sheet touches: opening reads the active deadline and
/// starting writes a duration.
class _FakeAudio extends ChangeNotifier implements AudioPlayerService {
  Duration? timer;
  DateTime? deadline;
  Duration? lastDuration;
  bool pending = false;
  bool finished = false;
  Song? song;

  @override
  Song? get currentSong => song;

  @override
  String? highResArtPathFor(Song? song) => null;

  @override
  DateTime? get sleepDeadline => deadline;

  @override
  bool get sleepActive => deadline != null || (pending && !finished);

  @override
  Duration? get sleepDuration => lastDuration;

  @override
  void setSleepTimer(Duration? duration) => timer = duration;

  @override
  void cancelSleepTimer() {
    timer = null;
    deadline = null;
    pending = false;
    finished = false;
    lastDuration = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
