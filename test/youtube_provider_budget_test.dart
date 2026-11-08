// Pins the video lookup deadline: a slow player call must end at the budget
// and cache nothing, so the first tap cannot fail while a late answer is
// cached for the second tap.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:atlas_music/media/providers/youtube_provider.dart';
import 'package:atlas_music/models/song.dart';

/// Answers slowly with a playable response that has no HLS master. The
/// attempt therefore completes without an error, so the orphaned future left
/// by the caller's timeout stays silent.
class _SlowPlayerClient extends http.BaseClient {
  static const _body = '{"playabilityStatus":{"status":"OK"}}';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(_body)]),
      200,
    );
  }
}

void main() {
  test('a slow lookup ends at the budget and caches nothing', () async {
    final provider = YouTubeProvider(
      httpClient: _SlowPlayerClient(),
      videoBudget: const Duration(milliseconds: 100),
    );
    final song = Song(
      id: 'atv',
      title: 'Song',
      artist: 'Artist',
      thumbnailUrl: '',
      duration: Duration.zero,
    );
    final sw = Stopwatch()..start();
    final source = await provider.videoSource(
      song,
      findMusicVideo: (_) async => 'found',
    );
    sw.stop();
    expect(source, isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
  }, timeout: const Timeout(Duration(seconds: 10)));
}
