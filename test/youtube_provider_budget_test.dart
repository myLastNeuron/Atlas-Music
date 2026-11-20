// Pins the video lookup deadline: a slow player call must end at the budget
// and cache nothing, so the first tap cannot fail while a late answer is
// cached for the second tap.
import 'dart:async';
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
    final lookup = await provider.videoLookup(
      song,
      findMusicVideo: (_) async => 'found',
    );
    sw.stop();
    expect(lookup.source, isNull);
    // Timed out: unknown, so the caller must not dim Video.
    expect(lookup.failed, isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('every attempt failing is unknown, not a proven miss', () async {
    final provider = YouTubeProvider(
      httpClient: _FailingClient(),
      videoBudget: const Duration(seconds: 2),
    );
    final lookup = await provider.videoLookup(_song());
    expect(lookup.source, isNull);
    expect(lookup.failed, isTrue);
  });

  test('a stalled first attempt still leaves time for the retry', () async {
    final client = _StallFirstPlayerClient();
    final provider = YouTubeProvider(
      httpClient: client,
      videoBudget: const Duration(milliseconds: 600),
    );
    final sw = Stopwatch()..start();
    final lookup = await provider.videoLookup(_song());
    sw.stop();
    expect(client.playerSends, 2);
    expect(lookup.failed, isFalse);
    expect(lookup.source, isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('a finder that never answers is unknown, not a proven miss', () async {
    final provider = YouTubeProvider(
      httpClient: _NoMasterClient(),
      videoBudget: const Duration(milliseconds: 300),
    );
    final lookup = await provider.videoLookup(
      _song(),
      findMusicVideo: (_) => Completer<String?>().future,
    );
    expect(lookup.source, isNull);
    expect(lookup.failed, isTrue);
  }, timeout: const Timeout(Duration(seconds: 10)));
}

Song _song() => Song(
      id: 'atv',
      title: 'Song',
      artist: 'Artist',
      thumbnailUrl: '',
      duration: Duration.zero,
    );

/// Fails every request, like a dead network.
class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw http.ClientException('offline');
  }
}

/// Answers every request at once with a playable video that has no HLS
/// master (a definitive "no video"), so a lookup can reach the finder.
class _NoMasterClient extends http.BaseClient {
  static const _body = '{"playabilityStatus":{"status":"OK"}}';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream.fromIterable([utf8.encode(_body)]), 200);
}

/// The first player call never answers; the second returns a playable video
/// with no HLS master (a definitive "no video").
class _StallFirstPlayerClient extends http.BaseClient {
  static const _noMaster = '{"playabilityStatus":{"status":"OK"}}';

  int playerSends = 0;
  final _stall = Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = http.StreamedResponse(
      Stream.fromIterable([utf8.encode(_noMaster)]),
      200,
    );
    if (!request.url.path.contains('/player')) return body;
    playerSends++;
    if (playerSends == 1) return _stall.future;
    return body;
  }
}
