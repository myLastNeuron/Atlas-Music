import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/youtube_service.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Song song(String title, String artist, String id) => Song(
      id: id,
      title: title,
      artist: artist,
      thumbnailUrl: '',
      duration: const Duration(seconds: 200),
      videoId: id,
    );

SearchVideo vid({
  String duration = '3:45',
  List<Thumbnail> thumbs = const [],
}) =>
    SearchVideo(
      VideoId('CUj2AWEJnwQ'),
      'Barbie World',
      'Nicki Minaj',
      'desc',
      duration,
      100,
      thumbs,
      '2 years ago',
      false,
      'channel1',
    );

void main() {
  test('duration parsing: mm:ss, hh:mm:ss, live/empty garbage', () {
    expect(YouTubeService.parseDurationString('3:45'),
        const Duration(minutes: 3, seconds: 45));
    expect(YouTubeService.parseDurationString('1:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(YouTubeService.parseDurationString('LIVE'), Duration.zero);
    expect(YouTubeService.parseDurationString(''), Duration.zero);
    expect(
        YouTubeService.parseDurationString('Streamed 2 hours ago'),
        Duration.zero);
  });

  test('mapper fills fields, falls back to ytimg thumbnail', () {
    final s = YouTubeService.songFromSearchVideo(vid());
    expect(s.id, 'CUj2AWEJnwQ');
    expect(s.videoId, 'CUj2AWEJnwQ');
    expect(s.title, 'Barbie World');
    expect(s.thumbnailUrl, contains('i.ytimg.com'));
    expect(s.duration, const Duration(minutes: 3, seconds: 45));
  });

  test('mapper never throws on hostile items', () {
    expect(
        () => YouTubeService.songFromSearchVideo(vid(duration: 'LIVE')),
        returnsNormally);
    expect(
        () => YouTubeService.songFromSearchVideo(vid(duration: '')),
        returnsNormally);
  });

  group('mergeResults', () {
    test('dedupes by video id and normalized title+artist', () {
      final out = YouTubeService.mergeResults(
        [
          song('Kesariya', 'Arijit Singh', 'a1'),
          song('Kesariya', 'Arijit Singh', 'a2'), // same track, new id
        ],
        [
          song('Kesariya', 'Arijit Singh - Topic', 'a3'), // channel noise
          song('Kesariya', 'Arijit Singh', 'a1'), // duplicate id
        ],
      );
      expect(out.length, 1);
      expect(out.single.id, 'a1');
    });

    test('keeps slowed/reverb variant distinct', () {
      final out = YouTubeService.mergeResults(
        [song('Kesariya', 'Arijit Singh', 'a1')],
        [song('Kesariya (Slowed + Reverb)', 'Arijit Singh', 'b1')],
      );
      expect(out.map((s) => s.id), ['a1', 'b1']);
    });

    test('respects the cap', () {
      final out = YouTubeService.mergeResults(
        [for (var i = 0; i < 5; i++) song('T$i', 'A', 'i$i')],
        const [],
        cap: 3,
      );
      expect(out.length, 3);
    });
  });
}
