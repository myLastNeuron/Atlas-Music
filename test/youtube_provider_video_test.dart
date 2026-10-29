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

  group('isArtTrackPlayerJson', () {
    // Live VISIONOS player responses (2026-10): the art track of "Kesariya"
    // names its auto-generated channel, the official video names its own.
    Map<String, dynamic> player(String author) => <String, dynamic>{
          'playabilityStatus': {'status': 'OK'},
          'streamingData': {'hlsManifestUrl': hlsUrl},
          'videoDetails': {
            'videoId': 'NJAv_7lHUIU',
            'author': author,
          },
        };

    test('a " - Topic" channel is an art track', () {
      expect(
          YouTubeProvider.isArtTrackPlayerJson(player('Arijit Singh - Topic')),
          isTrue);
    });

    test('case and padding do not matter', () {
      expect(
          YouTubeProvider.isArtTrackPlayerJson(player(' Arijit Singh - TOPIC ')),
          isTrue);
    });

    test('a real music video channel is not an art track', () {
      expect(YouTubeProvider.isArtTrackPlayerJson(player('TheWeekndVEVO')),
          isFalse);
      expect(YouTubeProvider.isArtTrackPlayerJson(player('Ed Sheeran')),
          isFalse);
    });

    test('hostile input: missing or non-string author returns false', () {
      expect(YouTubeProvider.isArtTrackPlayerJson(<String, dynamic>{}), isFalse);
      expect(
          YouTubeProvider.isArtTrackPlayerJson(<String, dynamic>{
            'videoDetails': {'author': null},
          }),
          isFalse);
      expect(
          YouTubeProvider.isArtTrackPlayerJson(<String, dynamic>{
            'videoDetails': 'not a map',
          }),
          isFalse);
    });
  });

  group('chooseVideoSource', () {
    test('a real own video wins and is cached', () {
      final pick = YouTubeProvider.chooseVideoSource(
        own: (url: 'own.m3u8', artTrack: false),
        found: (url: 'mv.m3u8', matchAudioPosition: false),
        hasFinder: true,
      );
      expect(pick!.source, (url: 'own.m3u8', matchAudioPosition: true));
      expect(pick.cache, isTrue);
    });

    test('an art track never wins over a finder that found nothing', () {
      expect(
        YouTubeProvider.chooseVideoSource(
          own: (url: 'art.m3u8', artTrack: true),
          found: null,
          hasFinder: true,
        ),
        isNull,
      );
    });

    test('a found music video replaces the art track', () {
      final pick = YouTubeProvider.chooseVideoSource(
        own: (url: 'art.m3u8', artTrack: true),
        found: (url: 'mv.m3u8', matchAudioPosition: false),
        hasFinder: true,
      );
      expect(pick!.source, (url: 'mv.m3u8', matchAudioPosition: false));
      expect(pick.cache, isTrue);
    });

    test('without a finder the art track is still returned, uncached', () {
      final pick = YouTubeProvider.chooseVideoSource(
        own: (url: 'art.m3u8', artTrack: true),
        found: null,
        hasFinder: false,
      );
      expect(pick!.source, (url: 'art.m3u8', matchAudioPosition: true));
      expect(pick.cache, isFalse);
    });

    test('no own stream and no finder means no video', () {
      expect(
        YouTubeProvider.chooseVideoSource(
            own: null, found: null, hasFinder: false),
        isNull,
      );
    });
  });
}
