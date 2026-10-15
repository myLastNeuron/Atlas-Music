import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/media/media_source.dart';

MediaSource src({
  String url = 'https://x/y',
  DateTime? expiresAt,
}) =>
    MediaSource(
      provider: MediaProvider.youTube,
      url: url,
      resolvedAt: DateTime.now(),
      expiresAt: expiresAt,
    );

void main() {
  test('expired URL detected', () {
    final expired = src(
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)));
    expect(expired.isExpired, isTrue);
    final fresh = src(
        expiresAt: DateTime.now().add(const Duration(hours: 5)));
    expect(fresh.isExpired, isFalse);
  });
}
