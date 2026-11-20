import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/backup_service.dart';
import 'package:atlas_music/services/storage_service.dart';

void main() {
  final song = Song(
    id: 'song-1',
    title: 'Midnight Drive',
    artist: 'Atlas',
    thumbnailUrl: 'https://example.com/a.jpg',
    duration: const Duration(seconds: 200),
    videoId: 'song-1',
    channel: 'Atlas Music',
  );

  Map<String, dynamic> backupJson() => {
        'app': 'atlas_music',
        'version': 1,
        'name': 'Ravi',
        'settings': {
          'themeMode': 'amoled',
          'artworkColor': true,
          'glassLevel': 0.8,
          'videoMode': true,
          'language': 'hindi',
          'genres': ['Pop'],
          'artists': ['Atlas'],
        },
        'likes': [song.toJson(), {'id': 'bad', 'duration': 'not-a-number'}],
        'history': {
          'recentlyPlayed': [song.toJson()],
          'listeningStats': {
            'song-1': {'playCount': 3, 'totalMs': 600000},
            // Hand-edited values: JSON decimals must not reach recordListen's
            // `as int` casts, and missing fields must be filled in.
            'song-2': {'playCount': 3.0, 'totalMs': 1000.5, 'skipTimes': [1.5, 2]},
          },
          'searchHistory': ['atlas', 42],
        },
        'fetchedSongs': [
          {'song': song.toJson(), 'foundAt': '2026-01-01T00:00:00.000Z'},
        ],
        'playlists': [
          {
            'id': 'playlist-1',
            'name': 'Night Mix',
            // One malformed song must not drop the whole playlist.
            'songs': [song.toJson(), {'id': 'bad-song', 'duration': 'nope'}],
            'createdAt': '2026-01-01T00:00:00.000Z',
            // Downloads never travel with a backup.
            'isDownloaded': true,
            'downloadedSongIds': ['song-1'],
            'isSystemManaged': false,
          },
          {
            'id': StorageService.downloadedPlaylistId,
            'name': 'Downloaded Music',
            'songs': [song.toJson()],
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
          {
            'id': 'playlist-2',
            // Wrong types must not drop the playlist or the whole import.
            'name': 123,
            'description': {'x': 1},
            'thumbnailUrl': [],
            'source': 7,
            'songs': [],
            'createdAt': 'not-a-date',
          },
        ],
      };

  test('parse restores every supported field and drops downloads', () {
    final data = BackupService.instance.parse(jsonEncode(backupJson()));

    expect(data.name, 'Ravi');
    expect(data.themeMode, 'amoled');
    expect(data.artworkColor, isTrue);
    expect(data.glassLevel, 0.8);
    expect(data.videoMode, isTrue);
    expect(data.language, 'hindi');
    expect(data.genres, {'Pop'});
    expect(data.artists, {'Atlas'});

    // A malformed song is skipped instead of failing the whole restore.
    expect(data.likes.length, 1);
    expect(data.likes.single.id, 'song-1');
    expect(data.recentlyPlayed.single.id, 'song-1');
    expect(data.listeningStats['song-1']!['playCount'], 3);
    final edited = data.listeningStats['song-2']!;
    expect(edited['playCount'], 3);
    expect(edited['totalMs'], 1000);
    expect(edited['skipCount'], 0);
    expect(edited['lastPlayed'], 0);
    expect(edited['skipTimes'], [1, 2]);
    expect(data.searchHistory, ['atlas']);
    expect(data.fetchedSongs.single.song.id, 'song-1');

    // The hidden Downloaded Music playlist and all download state are ignored.
    expect(data.playlists.length, 2);
    final playlist = data.playlists.first;
    expect(playlist.name, 'Night Mix');
    expect(playlist.songs.length, 1);
    expect(playlist.songs.single.id, 'song-1');
    expect(playlist.isDownloaded, isFalse);
    expect(playlist.offlineSongIds, isEmpty);
    expect(playlist.isSystemManaged, isFalse);

    // A playlist with wrong-typed metadata survives with model defaults.
    final sanitized = data.playlists.last;
    expect(sanitized.name, 'Untitled');
    expect(sanitized.description, isNull);
    expect(sanitized.thumbnailUrl, isNull);
    expect(sanitized.source, isNull);
    expect(sanitized.createdAt.year, greaterThanOrEqualTo(2026));
  });

  test('parse keeps sensible defaults when the file has no settings', () {
    final data = BackupService.instance.parse(jsonEncode({
      'app': 'atlas_music',
      'version': 1,
    }));

    expect(data.name, isNull);
    expect(data.themeMode, 'grey');
    expect(data.glassLevel, 0.5);
    expect(data.language, 'all');
    expect(data.likes, isEmpty);
    expect(data.playlists, isEmpty);
  });

  test('parse rejects other files and broken JSON', () {
    expect(
      () => BackupService.instance.parse(jsonEncode({'app': 'other'})),
      throwsFormatException,
    );
    expect(
      () => BackupService.instance.parse('{not json'),
      throwsFormatException,
    );
  });
}
