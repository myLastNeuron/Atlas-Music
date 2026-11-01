import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/services/video_handoff.dart';

// Regression: switching Video -> Song dropped the watched time for songs whose
// video is a separate music video (it starts at 0 while the song is not).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a real video maps its clock 1:1 onto the song', () {
    expect(
      mappedSongPosition(
        songStart: const Duration(minutes: 1, seconds: 20),
        videoStart: const Duration(minutes: 1, seconds: 20),
        videoPosition: const Duration(minutes: 1, seconds: 50),
        songDuration: const Duration(minutes: 4),
      ),
      const Duration(minutes: 1, seconds: 50),
    );
  });

  test('a found music video adds its watch time to the song position', () {
    expect(
      mappedSongPosition(
        songStart: const Duration(minutes: 2, seconds: 30),
        videoStart: Duration.zero,
        videoPosition: const Duration(seconds: 10),
        songDuration: const Duration(minutes: 4),
      ),
      const Duration(minutes: 2, seconds: 40),
    );
  });

  test('never seeks past the end of the song', () {
    expect(
      mappedSongPosition(
        songStart: const Duration(minutes: 3, seconds: 55),
        videoStart: Duration.zero,
        videoPosition: const Duration(seconds: 30),
        songDuration: const Duration(minutes: 4),
      ),
      const Duration(minutes: 4),
    );
  });

  test('scrubbing a shared video back moves the song back, not below zero', () {
    expect(
      mappedSongPosition(
        songStart: const Duration(minutes: 1),
        videoStart: const Duration(minutes: 1),
        videoPosition: Duration.zero,
        songDuration: const Duration(minutes: 4),
      ),
      Duration.zero,
    );
  });

  test('an unknown duration still maps without clamping', () {
    expect(
      mappedSongPosition(
        songStart: const Duration(minutes: 1),
        videoStart: Duration.zero,
        videoPosition: const Duration(minutes: 10),
        songDuration: Duration.zero,
      ),
      const Duration(minutes: 11),
    );
  });

  test('video loading is scoped to the song being loaded', () {
    final handoff = VideoHandoff();
    handoff.loading('a');
    expect(handoff.isLoadingFor('a'), isTrue);
    expect(handoff.isLoadingFor('b'), isFalse);

    // A different song finishing its attempt must not clear this one.
    handoff.loaded('b');
    expect(handoff.isLoadingFor('a'), isTrue);

    handoff.loaded('a');
    expect(handoff.isLoadingFor('a'), isFalse);
  });
}
