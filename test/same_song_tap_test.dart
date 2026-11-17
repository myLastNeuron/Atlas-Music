import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:atlas_music/services/audio_service.dart';

void main() {
  test('a tap on the loaded song is a no-op whether paused or playing', () {
    expect(
      AudioPlayerService.isSameSongTap(
        songId: 'a',
        currentSongId: 'a',
        activeSongId: 'a',
        completed: false,
      ),
      isTrue,
    );
  });

  test('another song still plays', () {
    expect(
      AudioPlayerService.isSameSongTap(
        songId: 'b',
        currentSongId: 'a',
        activeSongId: 'a',
        completed: false,
      ),
      isFalse,
    );
  });

  test('a song that never committed can retry', () {
    expect(
      AudioPlayerService.isSameSongTap(
        songId: 'a',
        currentSongId: 'a',
        activeSongId: null,
        completed: false,
      ),
      isFalse,
    );
  });

  test('a finished song can start over', () {
    expect(
      AudioPlayerService.isSameSongTap(
        songId: 'a',
        currentSongId: 'a',
        activeSongId: 'a',
        completed: true,
      ),
      isFalse,
    );
  });

  group('same-song load absorb', () {
    bool absorbs({bool playing = true, ProcessingState state = ProcessingState.ready, int positionSec = 20, bool forceReload = false}) =>
        AudioPlayerService.absorbsLoad(
          sameSong: true,
          playing: playing,
          state: state,
          position: Duration(seconds: positionSec),
          forceReload: forceReload,
        );

    test('a playing song past 5s absorbs a duplicate load', () {
      expect(absorbs(), isTrue);
    });

    test('a finished song reloads: playing stays true at completed', () {
      expect(absorbs(state: ProcessingState.completed), isFalse);
    });

    test('a forced reload (premature-completion recovery) is never absorbed',
        () {
      expect(absorbs(forceReload: true), isFalse);
    });

    test('an early load is not absorbed', () {
      expect(absorbs(positionSec: 2), isFalse);
    });
  });
}
