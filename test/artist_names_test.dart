import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/models/song.dart';

Song _s(String artist) => Song(
    id: 'x',
    title: 't',
    artist: artist,
    thumbnailUrl: '',
    duration: Duration.zero);

void main() {
  test('artistNames splits multiple credited artists', () {
    expect(_s('Arijit Singh').artistNames, ['Arijit Singh']);
    expect(_s('A, B & C feat. D').artistNames, ['A', 'B', 'C', 'D']);
    expect(_s('Jay x Kay').artistNames, ['Jay', 'Kay']);
  });
}
