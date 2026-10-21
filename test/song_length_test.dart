import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/widgets/song_actions.dart';

Song song(Duration d) => Song(
      id: 'id',
      title: 'Title',
      artist: 'Artist',
      thumbnailUrl: '',
      duration: d,
    );

void main() {
  testWidgets('a song row shows its length', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Row(children: [
        songLength(song(const Duration(minutes: 3, seconds: 45)))
      ])),
    ));
    expect(find.text('3:45'), findsOneWidget);
  });

  testWidgets('an unknown length renders nothing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Row(children: [songLength(song(Duration.zero))])),
    ));
    expect(find.byType(Text), findsNothing);
  });
}
