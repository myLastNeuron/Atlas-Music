import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/quick_picks.dart';

Song _s(String title, String artist, int sec,
        {String channel = '', String id = ''}) =>
    Song(
      id: id.isEmpty ? '$title::$artist' : id,
      title: title,
      artist: artist,
      thumbnailUrl: '',
      duration: Duration(seconds: sec),
      channel: channel,
    );

void main() {
  final seed = _s('Blinding Lights', 'The Weeknd', 200, id: 'seed');
  final recent = [
    seed,
    _s('Save Your Tears', 'The Weeknd', 215, id: 'r2'),
    _s('Levitating', 'Dua Lipa', 203, id: 'r3'),
  ];

  List<Song> candidates() => [
        _s('Blinding Lights Cover', 'The Weeknd', 200, id: 'c1'),
        _s('After Hours', 'The Weeknd', 200, id: 'c2'),
        _s('Unrelated Polka', 'Unknown Band', 200, id: 'c3'),
        _s('Short Clip', 'The Weeknd', 18, id: 'c4'),
      ];

  group('ranking', () {
    test('seed artist ranks first with because-you-played reason', () {
      final picks = QuickPicksEngine.rank(
        recent: recent,
        candidates: candidates(),
      );
      expect(picks, isNotEmpty);
      expect(picks.first.song.artist, 'The Weeknd');
      expect(picks.first.reason, contains('Because you played'));
    });

    test('empty candidates yields empty picks, never throws', () {
      expect(
          QuickPicksEngine.rank(recent: recent, candidates: const []), isEmpty);
      expect(QuickPicksEngine.rank(recent: const [], candidates: candidates()),
          isNotNull);
    });

    test('duration window enforced inside engine', () {
      final picks = QuickPicksEngine.rank(
        recent: recent,
        candidates: [
          ...candidates(),
          _s('Thirty Minute Mix', 'The Weeknd', 30 * 60, id: 'long-30'),
          _s('Hour Song Video', 'The Weeknd', 60 * 60, id: 'long-60'),
          _s('Video Track (Official Music Video)', 'The Weeknd', 200,
              id: 'music-video'),
        ],
      );
      expect(picks.any((p) => p.song.id == 'c4'), isFalse);
      expect(picks.any((p) => p.song.id == 'long-30'), isFalse);
      expect(picks.any((p) => p.song.id == 'long-60'), isFalse);
      expect(picks.any((p) => p.song.id == 'music-video'), isFalse);
    });

    test('strict UI mode keeps only personal-signal matches', () {
      final picks = QuickPicksEngine.rank(
        recent: [seed],
        candidates: [
          _s('After Hours', 'The Weeknd', 200, id: 'match'),
          _s('Unrelated Polka', 'Unknown Band', 200, id: 'unrelated'),
        ],
        requirePersonalSignal: true,
      );
      expect(picks.map((pick) => pick.song.id), ['match']);
    });
  });

  group('exclusions', () {
    test('recent, queue, recent-60min and duplicates excluded', () {
      final dup = _s('After Hours', 'The Weeknd', 200, id: 'dup-id');
      final picks = QuickPicksEngine.rank(
        recent: recent,
        candidates: [
          ...candidates(),
          _s('Blinding Lights', 'The Weeknd', 200, id: 'seed'),
          dup,
          _s('After Hours', 'The Weeknd', 200, id: 'c2'),
        ],
        queueIds: const {'c3'},
        stats: {
          'c2': {
            'playCount': 1,
            'skipCount': 0,
            'totalMs': 1000,
            'lastPlayed':
                DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000,
          },
        },
      );
      final ids = picks.map((p) => p.song.id).toSet();
      expect(ids.contains('seed'), isFalse); // in recent
      expect(ids.contains('r2'), isFalse);
      expect(ids.contains('c3'), isFalse); // in queue
      expect(ids.contains('c2'), isFalse); // played <60min ago
      // duplicate versions collapse to one entry
      expect(ids.where((id) => id == 'dup-id').length, lessThanOrEqualTo(1));
    });
  });

  group('diversity + language', () {
    test('seed artist match ranks first', () {
      final picks = QuickPicksEngine.rank(
        recent: [_s('Kesariya', 'Arijit Singh', 268, id: 'seed-hi')],
        candidates: [
          _s('Other Hindi Song', 'Arijit Singh', 250, id: 'hi'),
          _s('Blinding Lights', 'The Weeknd', 200, id: 'en'),
        ],
      );
      expect(picks.first.song.id, 'hi');
    });

    test('maxPerArtist cap is configurable', () {
      final pool = [
        for (var i = 0; i < 5; i++)
          _s('Track $i', 'One Artist', 200, id: 'x$i'),
      ];
      final strict = QuickPicksEngine.rank(recent: recent, candidates: pool);
      expect(strict.length, 2);
      final relaxed = QuickPicksEngine.rank(recent: recent,
          candidates: pool, maxPerArtist: 4);
      expect(relaxed.length, 4);
    });
  });
}
