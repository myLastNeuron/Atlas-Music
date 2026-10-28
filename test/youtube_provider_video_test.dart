import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/media/providers/youtube_provider.dart';

/// Pins `hlsMasterFromPlayerJson`: only a playable ("OK") player response may
/// yield an HLS master, so a bot-gated response can never leak a URL into the
/// Video path.
void main() {
  const hlsUrl = 'https://manifest.googlevideo.com/api/manifest/hls_playlist/vid/abc.m3u8';

  test('playable response returns its exact hlsManifestUrl', () {
    final json = <String, dynamic>{
      'playabilityStatus': {'status': 'OK'},
      'streamingData': {'hlsManifestUrl': hlsUrl},
    };
    expect(YouTubeProvider.hlsMasterFromPlayerJson(json), hlsUrl);
  });

  test('LOGIN_REQUIRED response with a URL present returns null', () {
    final json = <String, dynamic>{
      'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
      'streamingData': {'hlsManifestUrl': hlsUrl},
    };
    expect(YouTubeProvider.hlsMasterFromPlayerJson(json), isNull);
  });

  test('playable without streamingData returns null and does not throw', () {
    final json = <String, dynamic>{
      'playabilityStatus': {'status': 'OK'},
    };
    expect(YouTubeProvider.hlsMasterFromPlayerJson(json), isNull);
  });

  test('playable streamingData without hlsManifestUrl returns null', () {
    final json = <String, dynamic>{
      'playabilityStatus': {'status': 'OK'},
      'streamingData': {'formats': []},
    };
    expect(YouTubeProvider.hlsMasterFromPlayerJson(json), isNull);
  });

  test('playable empty hlsManifestUrl returns null', () {
    final json = <String, dynamic>{
      'playabilityStatus': {'status': 'OK'},
      'streamingData': {'hlsManifestUrl': ''},
    };
    expect(YouTubeProvider.hlsMasterFromPlayerJson(json), isNull);
  });

  test('playable null streamingData returns null', () {
    final json = <String, dynamic>{
      'playabilityStatus': {'status': 'OK'},
      'streamingData': null,
    };
    expect(YouTubeProvider.hlsMasterFromPlayerJson(json), isNull);
  });

  test('hostile input: null status or null playabilityStatus returns null', () {
    final nullStatus = <String, dynamic>{
      'playabilityStatus': {'status': null},
      'streamingData': {'hlsManifestUrl': hlsUrl},
    };
    expect(YouTubeProvider.hlsMasterFromPlayerJson(nullStatus), isNull);

    final nullPlayability = <String, dynamic>{
      'playabilityStatus': null,
      'streamingData': {'hlsManifestUrl': hlsUrl},
    };
    expect(YouTubeProvider.hlsMasterFromPlayerJson(nullPlayability), isNull);
  });
}
