import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/screens/player_screen.dart';
import 'package:atlas_music/services/audio_service.dart';
import 'package:atlas_music/services/theme_settings.dart';
import 'package:atlas_music/widgets/app_transitions.dart';
import 'package:atlas_music/widgets/liquid_background.dart';
import 'package:atlas_music/widgets/mini_player.dart';

// Regression: the player's async state (like, artwork colour, up-next peek)
// used to land a few frames into the 360 ms card flight, rebuilding the whole
// page and re-rasterising its window-sized layer for the rest of the flight.
// It is held until the route settles, and the flight's cover bitmap is decoded
// when the track changes instead of when the bar is tapped.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    PlayerScreen.openCount = 0;
  });

  group('FlightHold', () {
    test('holds updates while the flight runs, then applies them once', () {
      var rebuilds = 0;
      final applied = <String>[];
      final hold = FlightHold((update) {
        rebuilds++;
        update();
      });

      hold.apply(() => applied.add('like'));
      hold.apply(() => applied.add('accent'));
      expect(applied, isEmpty, reason: 'nothing lands mid-flight');
      expect(rebuilds, 0);

      hold.release();
      expect(applied, ['like', 'accent']);
      expect(rebuilds, 1, reason: 'one rebuild for every held update');

      // After the flight, updates go straight through again.
      hold.apply(() => applied.add('next'));
      expect(applied, ['like', 'accent', 'next']);
      expect(rebuilds, 2);

      // A second release is a no-op, never a replay.
      hold.release();
      expect(applied, ['like', 'accent', 'next']);
      expect(rebuilds, 2);
    });

    test('does not hold when no flight is running', () {
      var rebuilds = 0;
      final applied = <String>[];
      final hold = FlightHold((update) {
        rebuilds++;
        update();
      })
        ..holding = false;

      hold.apply(() => applied.add('like'));
      expect(applied, ['like'], reason: 'a player opened without a flight');
      expect(rebuilds, 1);

      hold.release();
      expect(applied, ['like']);
      expect(rebuilds, 1);
    });
  });

  testWidgets(
      'opening the player lands like, accent and up-next after the '
      'flight, not during it', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final cover = await _coverFile(tester, const Color(0xFFB03060));
    addTearDown(() => cover.deleteSync());

    final song = Song(
      id: 'song-a',
      title: 'Song A',
      artist: 'Artist',
      thumbnailUrl: '',
      duration: const Duration(seconds: 200),
      videoId: 'vid-a',
    );
    // The song is liked on disk: the player reads that a few frames in.
    SharedPreferences.setMockInitialValues({
      'liked_songs': '[${_songJson(song)}]',
      'player_artwork_color': true,
    });
    final theme = ThemeSettings();
    await theme.load();

    final audio = _FakeAudio(song, artPath: cover.path);
    addTearDown(audio.dispose);

    await tester.pumpWidget(_harness(audio, theme, _openButton()));
    await tester.tap(find.text('open'));
    // First frame of the flight: the page is mounted, the card is the bar.
    await tester.pump();
    await tester.pump();
    expect(PlayerScreen.openCount, 1);
    await tester.pump(const Duration(milliseconds: 40));

    // Mid-flight, the up-next peek fills in and the like/accent reads land.
    audio.upcomingSongs = [
      Song(
        id: 'song-b',
        title: 'Song B',
        artist: 'Artist',
        thumbnailUrl: '',
        duration: const Duration(seconds: 180),
      ),
      Song(
        id: 'song-c',
        title: 'Song C',
        artist: 'Artist',
        thumbnailUrl: '',
        duration: const Duration(seconds: 190),
      ),
    ];
    audio.notifyListeners();
    // The artwork-colour sample is a real decode: let the real event loop run
    // it, while the flight's fake clock stays where it is.
    await _settleImages(tester);
    await tester.pump();

    // Still flying: none of the three has rebuilt the page.
    expect(tester.getRect(find.byKey(const ValueKey('player_sheet'))).width,
        lessThan(400),
        reason: 'the card has not landed yet');
    expect(find.byIcon(Icons.favorite), findsNothing,
        reason: 'the like must not land mid-flight');
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(
        tester.widget<LiquidBackground>(find.byType(LiquidBackground)).gradient,
        isNull,
        reason: 'the accent must not repaint the page mid-flight');
    expect(find.text('UP NEXT'), findsNothing,
        reason: 'the peek must not pop in mid-flight');

    // The flight ends: everything held lands in one go, exactly as before.
    // Nothing real-async runs from here on, so the accent can only appear if
    // it was decoded mid-flight and released with the rest.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsNothing);
    expect(
        tester.widget<LiquidBackground>(find.byType(LiquidBackground)).gradient,
        isNotNull);
    expect(find.text('UP NEXT'), findsOneWidget);
    expect(find.text('Song B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the mini bar warms the flight cover on a track change and leaks '
      'nothing across open/close cycles', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final coverA = await _coverFile(tester, const Color(0xFF2050A0));
    final coverB = await _coverFile(tester, const Color(0xFFA05020));
    addTearDown(() {
      coverA.deleteSync();
      coverB.deleteSync();
    });

    final songA = Song(
      id: 'song-a',
      title: 'Song A',
      artist: 'Artist',
      thumbnailUrl: '',
      duration: const Duration(seconds: 200),
    );
    final songB = Song(
      id: 'song-b',
      title: 'Song B',
      artist: 'Artist',
      thumbnailUrl: '',
      duration: const Duration(seconds: 200),
    );
    final theme = ThemeSettings();
    await theme.load();
    final audio = _FakeAudio(songA, artPath: coverA.path, playing: true);
    addTearDown(audio.dispose);

    await tester.pumpWidget(_harness(
      audio,
      theme,
      const Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MiniPlayer(),
        ),
      ),
    ));
    await tester.pump();

    // No tap: the bar decodes the player's cover for the current track.
    await _settleImages(tester);
    expect(PaintingBinding.instance.imageCache.currentSize, 1,
        reason: 'the current track\'s flight cover is decoded up front');

    // A track change warms the next cover, still without a tap.
    audio
      ..song = songB
      ..artPath = coverB.path
      ..notifyListeners();
    await tester.pump();
    await _settleImages(tester);
    expect(PaintingBinding.instance.imageCache.currentSize, 2,
        reason: 'the new track\'s flight cover is decoded up front');

    // Repeated mini -> full -> mini toggles leave nothing behind.
    final baselineListeners = audio.listeners;
    final nav = find.byKey(const ValueKey('mini_nav_area'));
    for (var i = 0; i < 2; i++) {
      await tester.tap(nav);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(PlayerScreen.openCount, 1, reason: 'one player, never a second');
      expect(audio.listeners, baselineListeners + 1,
          reason: 'one page listener, never a stacked one');
      if (i == 0) {
        // Playback is running, so the cover breathes: its controller is live
        // going into the close below, where the framework asserts on a ticker
        // that outlives its state.
        final breath = find.ancestor(
          of: find.descendant(
              of: find.byType(PlayerScreen), matching: find.byType(Hero)),
          matching: find.byType(ScaleTransition),
        );
        final before = tester.widget<ScaleTransition>(breath.first).scale.value;
        await tester.pump(const Duration(seconds: 3));
        final after = tester.widget<ScaleTransition>(breath.first).scale.value;
        expect(after, greaterThan(before),
            reason: 'the cover breath is running while the player is open');
      }

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(PlayerScreen), findsNothing);
      expect(PlayerScreen.openCount, 0);
      expect(audio.listeners, baselineListeners,
          reason: 'the page listener is removed on close');
    }

    // The bar is the only thing left: nothing tickers, nothing is pending.
    await tester.pumpAndSettle();
    expect(PlayerScreen.isOpen, isFalse);
    expect(PlayerScreen.isClosing, isFalse);
    expect(tester.takeException(), isNull);
  });
}

/// The player behind the bar, with only the surface the player and the bar
/// read. Everything else is a forwarder that never gets called here.
class _FakeAudio extends ChangeNotifier implements AudioPlayerService {
  _FakeAudio(this.song, {this.artPath, this.playing = false});

  Song? song;
  String? artPath;
  bool playing;
  List<Song> upcomingSongs = const [];

  /// Live listeners, so a leaked one is visible to a test.
  int listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }

  @override
  Song? get currentSong => song;

  @override
  String? highResArtPathFor(Song? song) => artPath;

  @override
  List<Song> get upcoming => upcomingSongs;

  @override
  Song? get pinnedNext => null;

  @override
  bool get isLoading => false;

  @override
  bool get upNextLoading => false;

  @override
  bool get isPlaying => playing;

  @override
  String? get lastFailure => null;

  @override
  bool get pausedForOffline => false;

  @override
  bool get degradedOffline => false;

  @override
  bool get shuffleEnabled => false;

  @override
  LoopMode get loopMode => LoopMode.off;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => const Duration(seconds: 200);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _harness(_FakeAudio audio, ThemeSettings theme, Widget home) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AudioPlayerService>.value(value: audio),
      ChangeNotifierProvider<ThemeSettings>.value(value: theme),
    ],
    child: MaterialApp(home: home),
  );
}

Widget _openButton() => Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => pushAppPage(
              context,
              const PlayerScreen(),
              routeName: PlayerScreen.routeName,
              slideUp: true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

/// Lets the real event loop finish the image decode the widget just started:
/// each read/decode hop lands back in the test's fake zone, which only a pump
/// flushes — hence the rounds. The fake clock never moves, so any transition
/// stays exactly where it was.
Future<void> _settleImages(WidgetTester tester) async {
  // Fixed rounds, not "until no pending image": reading the decoded pixels for
  // the artwork colour is another real hop after the image cache is done.
  for (var round = 0; round < 12; round++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

/// A real PNG on disk, so the artwork-colour and cover paths decode for real.
Future<File> _coverFile(WidgetTester tester, Color color) async {
  late File file;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 16, 16),
      Paint()..color = color,
    );
    final image = await recorder.endRecording().toImage(16, 16);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = await Directory.systemTemp.createTemp('player_cover');
    file = File('${dir.path}/cover.png')
      ..writeAsBytesSync(data!.buffer.asUint8List());
  });
  return file;
}

String _songJson(Song song) =>
    '{"id":"${song.id}","title":"${song.title}","artist":"${song.artist}",'
    '"thumbnailUrl":"${song.thumbnailUrl}","duration":'
    '${song.duration.inSeconds},"videoId":"${song.videoId}"}';
