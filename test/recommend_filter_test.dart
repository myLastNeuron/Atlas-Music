import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/screens/home_screen.dart';

Song _s(String title, String artist, int sec, [String channel = '']) => Song(
      id: '$title$artist',
      title: title,
      artist: artist,
      thumbnailUrl: '',
      duration: Duration(seconds: sec),
      channel: channel,
    );

void main() {
  test('drops clips, unknown lengths, and long videos (>7 min)', () {
    final out = filterRecommendedSongs([
      _s('Short Clip', 'A', 18),
      _s('Mystery Stream', 'A', 0),
      _s('Movie Scene', 'A', 720),
      _s('Long Song', 'A', 30 * 60),
      _s('Hour Mix', 'A', 60 * 60),
      _s('Full Song', 'A', 210),
    ]);
    expect(out.map((s) => s.title), ['Full Song']);
  });

  test('drops music-video uploads even when their duration is song-length', () {
    final out = filterRecommendedSongs([
      _s('Track Name (Official Music Video)', 'Artist', 210),
      _s('Track Name - Official Video', 'Artist', 210),
      _s('Track Name (Official Audio)', 'Artist', 210),
    ]);
    expect(out.map((s) => s.title), ['Track Name (Official Audio)']);
  });

  test('drops remix/edit/slowed/reverb variants', () {
    final out = filterRecommendedSongs([
      _s('Kesariya (Slowed + Reverb)', 'Arijit Singh', 200),
      _s('Kesariya - DJ Edit', 'Arijit Singh', 200),
      _s('Kesariya Remix', 'DJ X', 200),
      _s('Kesariya', 'Arijit Singh', 268),
    ]);
    expect(out.length, 1);
    expect(out.single.title, 'Kesariya');
  });

  test('clean song catalog results do not need an official title suffix', () {
    final out = filterRecommendedSongs([
      _s('After Hours', 'The Weeknd', 361, 'The Weeknd'),
      _s('One Word', 'Adele', 210, 'Adele'),
      _s('Song Lyrics Video', 'Adele', 210, 'Adele'),
      _s('Unknown Duration', 'Adele', 0, 'Adele'),
    ]);
    expect(out.map((song) => song.title), ['After Hours', 'One Word']);
  });

  test('word boundary: credit survives edit rule', () {
    final out = filterRecommendedSongs([
      _s('Credit Song', 'Accredited Band', 200),
    ]);
    expect(out.length, 1);
  });

  test('canonical artist gate kills loose-search mismatch', () {
    final out = filterRecommendedSongs(
      [
        _s('Kesariya', 'Arijit Singh', 268),
        _s('Random Song', 'Unknown Band', 200),
      ],
      canonicalArtist: 'Arijit Singh',
    );
    expect(out.map((s) => s.title), ['Kesariya']);
  });

  test('alien uploader channel rejected, official allowed', () {
    final songs = [
      _s('Kesariya', 'Arijit Singh', 268, 'coyote clipz'),
      _s('Kesariya', 'Arijit Singh', 268, 'Arijit Singh'),
      _s('Kesariya', 'Arijit Singh', 268, 'SonyMusicIndiaVEVO'),
      _s('Kesariya', 'Arijit Singh', 268, 'Arijit Singh - Topic'),
      _s('Kesariya', 'Arijit Singh', 268, ''),
    ];
    final out = filterRecommendedSongs(songs, canonicalArtist: 'Arijit Singh');
    expect(out.map((s) => s.channel), [
      'Arijit Singh',
      'SonyMusicIndiaVEVO',
      'Arijit Singh - Topic',
      '',
    ]);
  });
}
