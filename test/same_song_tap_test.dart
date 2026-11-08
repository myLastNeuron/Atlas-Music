import 'package:flutter_test/flutter_test.dart';
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
}
