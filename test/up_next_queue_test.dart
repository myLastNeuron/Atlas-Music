import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/audio_service.dart';

/// A YouTube-shaped track: videoId equals id, which is what broke the dedupe.
Song _yt(String id) => Song(
      id: id,
      title: 'Song $id',
      artist: 'Artist',
      thumbnailUrl: '',
      duration: const Duration(seconds: 200),
      videoId: id,
    );

/// Regression tests for the always-ten up-next window: the deficit arithmetic,
/// the refill gate, and the dedupe that discarded every ranked song (id and
/// videoId are the same string for YouTube tracks).
void main() {
  group('refill dedupe', () {
    test('keeps every fresh ranked song (id == videoId)', () {
      final seen = <String>{'now-playing'};
      final fresh = [_yt('a'), _yt('b'), _yt('c')];
      final kept = AudioPlayerService.takeNewSongs(fresh, seen);
      expect(kept.map((s) => s.id), ['a', 'b', 'c'],
          reason: 'the old `||` dedupe dropped all of them');
      expect(seen, containsAll(['a', 'b', 'c']));
    });

    test('drops repeats of the queue, the spare and itself', () {
      final seen = <String>{'now-playing'};
      final fresh = [_yt('a'), _yt('a'), _yt('now-playing')];
      expect(AudioPlayerService.takeNewSongs(fresh, seen).map((s) => s.id),
          ['a']);
    });

    test('respects the requested depth', () {
      final seen = <String>{};
      final fresh = [for (var i = 0; i < 10; i++) _yt('s$i')];
      expect(AudioPlayerService.takeNewSongs(fresh, seen, limit: 4).length, 4);
      expect(seen.length, 4, reason: 'only kept songs are remembered');
    });
  });
  group('up-next deficit', () {
    test('a lone song (search result) needs a full ten', () {
      expect(AudioPlayerService.upNextDeficit(1, 0), 10);
      expect(AudioPlayerService.upNextDeficit(0, -1), 10);
    });

    test('a short playlist tail is topped up to ten, not replaced', () {
      expect(AudioPlayerService.upNextDeficit(3, 0), 8);
      expect(AudioPlayerService.upNextDeficit(11, 0), 0);
    });

    test('a deep playlist asks for nothing', () {
      expect(AudioPlayerService.upNextDeficit(50, 0), isNegative);
      expect(AudioPlayerService.upNextDeficit(50, 45), 6);
    });
  });

  group('refill target', () {
    test('first song fills the window plus the spare', () {
      expect(AudioPlayerService.upNextRefillTarget(10, 0), 14);
    });

    test('a stocked spare costs one song, not another full batch', () {
      expect(AudioPlayerService.upNextRefillTarget(1, 4), 1);
      expect(AudioPlayerService.upNextRefillTarget(1, 3), 2);
    });

    test('a full window with a stocked spare asks for nothing', () {
      expect(AudioPlayerService.upNextRefillTarget(0, 4), 0);
      expect(AudioPlayerService.upNextRefillTarget(-39, 4), 0);
    });
  });

  group('refill gate', () {
    test('a skip mid-build re-runs the pass instead of dropping it', () {
      final gate = TopUpCoalescer();
      expect(gate.begin(), isTrue);
      expect(gate.running, isTrue);
      expect(gate.begin(), isFalse, reason: 'second caller waits, not drops');
      expect(gate.end(), isTrue, reason: 'finish must report the owed pass');
      expect(gate.running, isFalse);
      expect(gate.begin(), isTrue, reason: 'gate is free again');
    });

    test('a superseded build can re-arm the gate itself', () {
      final gate = TopUpCoalescer();
      gate.begin();
      gate.again(); // picks ranked for the previous song
      expect(gate.end(), isTrue);
      expect(gate.end(), isFalse, reason: 'the debt is consumed once');
    });

    test('a clean pass owes nothing', () {
      final gate = TopUpCoalescer();
      gate.begin();
      expect(gate.end(), isFalse);
    });
  });
}
