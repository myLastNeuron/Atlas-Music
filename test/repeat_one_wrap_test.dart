import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:atlas_music/services/audio_service.dart';

/// Repeat-one rewinds natively (no `completed` event), so the wrap is the
/// end-of-track signal. A source swap drops the position to 0 too; only a
/// wrap from the last two seconds may consume the pinned "Play next".
void main() {
  const threeMinutes = Duration(minutes: 3);

  bool wrap(
    Duration previous, {
    PositionDiscontinuityReason reason =
        PositionDiscontinuityReason.autoAdvance,
    Duration? duration = threeMinutes,
  }) =>
      AudioPlayerService.isRepeatOneWrap(
        reason: reason,
        trackDuration: duration,
        previousPosition: previous,
      );

  test('a wrap from the end of the track counts', () {
    expect(wrap(const Duration(seconds: 179)), isTrue);
    expect(wrap(threeMinutes), isTrue);
  });

  test('the last two seconds are inclusive', () {
    expect(wrap(threeMinutes - const Duration(seconds: 2)), isTrue);
    expect(
      wrap(threeMinutes -
          const Duration(seconds: 2) -
          const Duration(milliseconds: 1)),
      isFalse,
    );
  });

  test('a mid-track position drop does not count', () {
    expect(wrap(const Duration(seconds: 90)), isFalse);
  });

  test('a seek does not count', () {
    expect(
        wrap(const Duration(seconds: 179),
            reason: PositionDiscontinuityReason.seek),
        isFalse);
  });

  test('an unknown or empty duration does not count', () {
    expect(wrap(const Duration(seconds: 179), duration: null), isFalse);
    expect(
        wrap(const Duration(seconds: 179), duration: Duration.zero), isFalse);
  });
}
