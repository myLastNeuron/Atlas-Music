import 'package:atlas_music/models/playlist.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/screens/playlist_qr_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Playlist playlistWith(int count, {String name = 'Road Trip'}) => Playlist(
      id: 'p1',
      name: name,
      songs: [
        for (var i = 0; i < count; i++)
          Song(
            id: 'vid$i',
            title: 'Track $i',
            artist: 'Artist $i',
            thumbnailUrl: '',
            duration: const Duration(seconds: 200),
            videoId: 'vid$i',
          ),
      ],
      createdAt: DateTime.now(),
      source: 'local',
    );

Future<void> pump(WidgetTester tester, Playlist playlist) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: PlaylistQrScreen(playlist: playlist),
  ));
  await tester.pump();
}

void main() {
  testWidgets('shows the playlist name, song count and a share button',
      (tester) async {
    await pump(tester, playlistWith(4));
    expect(find.text('Share Playlist'), findsOneWidget);
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('4 songs · Atlas Music playlist'), findsOneWidget);
    expect(find.text('Share QR Code'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    // A short playlist needs one code, so there is no part pager.
    expect(find.textContaining('Part 1 of'), findsNothing);
  });

  testWidgets('long playlists page through every QR part', (tester) async {
    await pump(tester, playlistWith(120));
    expect(find.text('Part 1 of 2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(find.text('Part 2 of 2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(find.text('Part 1 of 2'), findsOneWidget);
    expect(find.textContaining('uses 2 parts'), findsOneWidget);
    // Dispose the screen so its auto-advance timer is cancelled.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('explains how the receiving app imports the code',
      (tester) async {
    await pump(tester, playlistWith(2));
    expect(find.textContaining('Library → Import'), findsOneWidget);
  });
}
