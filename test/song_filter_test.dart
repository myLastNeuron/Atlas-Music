import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/song_filter.dart';
import 'package:atlas_music/services/user_preferences.dart';

Song _s(String title, String artist, int sec,
        {String channel = '', String id = ''}) =>
    Song(
      id: id.isEmpty ? '$title$artist' : id,
      title: title,
      artist: artist,
      thumbnailUrl: '',
      duration: Duration(seconds: sec),
      channel: channel,
    );

void main() {
  group('duration window 00:45-07:00', () {
    test('rejects under 45s, keeps bounds, rejects over 7min', () {
      expect(SongFilter.inDurationWindow(_s('A', 'B', 44)), isFalse);
      expect(SongFilter.inDurationWindow(_s('A', 'B', 45)), isTrue);
      expect(SongFilter.inDurationWindow(_s('A', 'B', 200)), isTrue);
      expect(SongFilter.inDurationWindow(_s('A', 'B', 420)), isTrue);
      expect(SongFilter.inDurationWindow(_s('A', 'B', 421)), isFalse);
      expect(SongFilter.inDurationWindow(_s('A', 'B', 30 * 60)), isFalse);
      expect(SongFilter.inDurationWindow(_s('A', 'B', 60 * 60)), isFalse);
    });

    test('apply excludes official music videos from discovery listings', () {
      final out = SongFilter.apply([
        _s('Track (Official Music Video)', 'Artist', 200, id: 'video'),
        _s('Track (Official Audio)', 'Artist', 200, id: 'audio'),
      ]);
      expect(out.map((song) => song.id), ['audio']);
    });

    test('applyDiscovery rejects unknown durations and long-form titles', () {
      final out = SongFilter.applyDiscovery([
        _s('Normal Song', 'Artist', 200, id: 'ok'),
        _s('Mystery Upload', 'Artist', 0, id: 'unknown'),
        _s('1 Hour Loop', 'Artist', 200, id: 'hour'),
        _s('Greatest Hits Full Album', 'Artist', 200, id: 'album'),
        _s('Live Stream Session', 'Artist', 200, id: 'live'),
        _s('Track (Official Music Video)', 'Artist', 200, id: 'video'),
        _s('Long Mix', 'Artist', 1800, id: 'long'),
      ]);
      expect(out.map((song) => song.id), ['ok']);
    });

    test('unknown duration (0) is allowed, not a clip', () {
      // Zero means the metadata never carried a duration. Refusing it
      // broke all playback of such songs; known shorts are still removed.
      expect(SongFilter.inDurationWindow(_s('A', 'B', 0)), isTrue);
    });

    test('apply preserves order and drops violators', () {
      final out = SongFilter.apply([
        _s('Short', 'A', 18, id: 'short'),
        _s('Keep One', 'A', 200, id: 'k1'),
        _s('Movie', 'A', 900, id: 'long'),
        _s('Keep Two', 'A', 100, id: 'k2'),
      ]);
      expect(out.map((s) => s.id), ['k1', 'k2']);
    });
  });

  group('strict language gate', () {
    test('all allows everything in-window', () {
      expect(
          SongFilter.matchesLanguage(
              _s('Kesariya', 'Arijit Singh', 200), MusicLanguage.all),
          isTrue);
    });

    test('Devanagari text requires Hindi or Marathi', () {
      final s = _s('केसरिया', 'Arijit Singh', 200);
      expect(SongFilter.matchesLanguage(s, MusicLanguage.english), isFalse);
      expect(SongFilter.matchesLanguage(s, MusicLanguage.hindi), isTrue);
      expect(SongFilter.matchesLanguage(s, MusicLanguage.marathi), isTrue);
      expect(SongFilter.matchesLanguage(s, MusicLanguage.spanish), isFalse);
    });

    test('English selection drops Hindi anchor artists', () {
      // A Hindi song with an English title must still read as Hindi.
      final s = _s('Love You Zindagi', 'Arijit Singh', 200);
      expect(SongFilter.matchesLanguage(s, MusicLanguage.english), isFalse);
      expect(SongFilter.matchesLanguage(s, MusicLanguage.hindi), isTrue);
    });

    test('English selection drops Hangul and K-pop anchors', () {
      expect(
          SongFilter.matchesLanguage(
              _s('Dynamite', 'BTS', 200), MusicLanguage.english),
          isFalse);
      expect(
          SongFilter.matchesLanguage(
              _s('사랑', 'IU', 200), MusicLanguage.english),
          isFalse);
      expect(
          SongFilter.matchesLanguage(
              _s('Dynamite', 'BTS', 200), MusicLanguage.korean),
          isTrue);
    });

    test('Spanish selection keeps its artists, drops others', () {
      expect(
          SongFilter.matchesLanguage(
              _s('Tití Me Preguntó', 'Bad Bunny', 200), MusicLanguage.spanish),
          isTrue);
      expect(
          SongFilter.matchesLanguage(
              _s('Tití Me Preguntó', 'Bad Bunny', 200), MusicLanguage.english),
          isFalse);
      expect(
          SongFilter.matchesLanguage(
              _s('Blinding Lights', 'The Weeknd', 200), MusicLanguage.spanish),
          isTrue);
    });

    test('channel markers count (T-Series is Hindi)', () {
      final s = _s('Some Song', 'Unknown Artist', 200, channel: 'T-Series');
      expect(SongFilter.matchesLanguage(s, MusicLanguage.english), isFalse);
      expect(SongFilter.matchesLanguage(s, MusicLanguage.hindi), isTrue);
    });

    test('plain English pop passes English', () {
      expect(
          SongFilter.matchesLanguage(
              _s('Blinding Lights', 'The Weeknd', 200), MusicLanguage.english),
          isTrue);
    });

    test('apply combines both rules', () {
      final out = SongFilter.apply(
        [
          _s('Short Hindi', 'Arijit Singh', 30, id: 'a'),
          _s('Kesariya', 'Arijit Singh', 268, id: 'b'),
          _s('Blinding Lights', 'The Weeknd', 200, id: 'c'),
        ],
        language: MusicLanguage.english,
      );
      expect(out.map((s) => s.id), ['c']);
    });
  });
}
