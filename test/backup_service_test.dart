import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:atlas_music/models/playlist.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/screens/advanced_settings_screen.dart';
import 'package:atlas_music/services/backup_service.dart';
import 'package:atlas_music/services/storage_service.dart';
import 'package:atlas_music/services/theme_settings.dart';
import 'package:atlas_music/services/user_prefs.dart';

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
        'likes': [
          song.toJson(),
          {'id': 'bad', 'duration': 'not-a-number'}
        ],
        'history': {
          'recentlyPlayed': [song.toJson()],
          'listeningStats': {
            'song-1': {'playCount': 3, 'totalMs': 600000},
            // Hand-edited values: JSON decimals must not reach recordListen's
            // `as int` casts, and missing fields must be filled in.
            'song-2': {
              'playCount': 3.0,
              'totalMs': 1000.5,
              'skipTimes': [1.5, 2]
            },
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
            'songs': [
              song.toJson(),
              {'id': 'bad-song', 'duration': 'nope'}
            ],
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

  test('parse keeps the format version', () {
    expect(
      BackupService.instance.parse(jsonEncode({'app': 'atlas_music'})).version,
      1,
    );
    expect(
      BackupService.instance
          .parse(jsonEncode({'app': 'atlas_music', 'version': 2}))
          .version,
      2,
    );
    // A junk version reads as the format this build knows.
    expect(
      BackupService.instance
          .parse(jsonEncode({'app': 'atlas_music', 'version': 'two'}))
          .version,
      1,
    );
  });

  test('parse drops a duplicated like and sanitises dismissals', () {
    final data = BackupService.instance.parse(jsonEncode({
      'app': 'atlas_music',
      'version': 1,
      // The same song twice cannot be un-liked in one tap.
      'likes': [song.toJson(), song.toJson()],
      'notInterested': {
        'song-1': {'at': 1.9, 'artist': 'Atlas'},
        'song-2': {'at': 2},
        'song-3': 'not-a-map',
        '': {'at': 3},
      },
    }));

    expect(data.likes.length, 1);
    expect(data.notInterested.keys, {'song-1', 'song-2'});
    expect(data.notInterested['song-1'], {'at': 1, 'artist': 'Atlas'});
    expect(data.notInterested['song-2']!['artist'], '');
    expect(data.notInterested['song-2']!['at'], 2);
  });

  test('parse keeps the export date, and the dialog shows it', () {
    final data = BackupService.instance.parse(jsonEncode({
      'app': 'atlas_music',
      'exportedAt': '2026-11-20T12:00:00.000Z',
    }));

    expect(data.exportedAt, DateTime.utc(2026, 11, 20, 12));
    final local = DateTime.utc(2026, 11, 20, 12).toLocal();
    expect(
      AdvancedSettingsScreen.describeBackup(data),
      contains('Exported ${local.day} Nov ${local.year}'),
    );

    // A date nobody can read says nothing instead of inventing one.
    final junk = BackupService.instance
        .parse(jsonEncode({'app': 'atlas_music', 'exportedAt': 'someday'}));
    expect(junk.exportedAt, isNull);
    expect(
      AdvancedSettingsScreen.describeBackup(junk),
      isNot(contains('Exported')),
    );
  });

  test('parse keeps a playlist cover only when the file still exists', () {
    final dir = Directory.systemTemp.createTempSync('atlas_backup_test');
    final cover = File('${dir.path}/cover.png')..writeAsBytesSync(const [0]);
    Map<String, dynamic> withCover(String? path) => {
          'app': 'atlas_music',
          'version': 1,
          'playlists': [
            {
              'id': 'p1',
              'name': 'Night Mix',
              'songs': [song.toJson()],
              'createdAt': '2026-01-01T00:00:00.000Z',
              'coverPath': path,
            },
          ],
        };

    expect(
      BackupService.instance
          .parse(jsonEncode(withCover(cover.path)))
          .playlists
          .single
          .coverPath,
      cover.path,
    );
    expect(
      BackupService.instance
          .parse(jsonEncode(withCover('/nowhere/cover.png')))
          .playlists
          .single
          .coverPath,
      isNull,
    );
    dir.deleteSync(recursive: true);
  });

  group('apply', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('a backup without a name keeps the current one', () async {
      final prefs = UserPrefs();
      await prefs.setName('Keeper');

      await BackupService.instance.apply(
        BackupService.instance.parse(jsonEncode({'app': 'atlas_music'})),
        theme: ThemeSettings(),
      );

      expect(await prefs.getName(), 'Keeper');
    });

    test('a backup with a name replaces it', () async {
      final prefs = UserPrefs();
      await prefs.setName('Old');

      await BackupService.instance.apply(
        BackupService.instance
            .parse(jsonEncode({'app': 'atlas_music', 'name': 'Ravi'})),
        theme: ThemeSettings(),
      );

      expect(await prefs.getName(), 'Ravi');
    });

    test('restore enforces the history and search caps', () async {
      final storage = StorageService();
      final history = [
        for (var i = 0; i < 60; i++)
          Song(
            id: 'h$i',
            title: 'Song $i',
            artist: 'Atlas',
            thumbnailUrl: '',
            duration: const Duration(seconds: 100),
          ),
      ];
      final searches = [for (var i = 0; i < 30; i++) 'query $i'];

      await BackupService.instance.apply(
        BackupData(recentlyPlayed: history, searchHistory: searches),
        theme: ThemeSettings(),
      );

      expect((await storage.getRecentlyPlayed()).length,
          StorageService.recentlyPlayedLimit);
      expect((await storage.getSearchHistory()).length,
          StorageService.searchHistoryLimit);
      // The oldest entries are the ones dropped: newest-first is preserved.
      expect((await storage.getRecentlyPlayed()).first.id, 'h0');
    });

    test('a restored like clears the dismissal the file also carried',
        () async {
      final storage = StorageService();

      await BackupService.instance.apply(
        BackupData(
          likes: [song],
          notInterested: {
            song.id: {'at': 1, 'artist': 'Atlas'},
          },
        ),
        theme: ThemeSettings(),
      );

      expect((await storage.getLikedSongs()).single.id, song.id);
      expect(await storage.getNotInterested(), isEmpty);
    });

    test('restore rebuilds a playlist offline set from this phone', () async {
      final storage = StorageService();
      final offline = Song(
        id: 'song-2',
        title: 'Still Here',
        artist: 'Atlas',
        thumbnailUrl: '',
        duration: const Duration(seconds: 120),
      );
      // The audio was cached in this install before the restore.
      await storage.addDownloadedSong(offline);
      final playlist = Playlist(
        id: 'p1',
        name: 'Night Mix',
        createdAt: DateTime.utc(2026, 1, 1),
        songs: [offline, song],
      );

      await BackupService.instance.apply(
        BackupData(playlists: [playlist]),
        theme: ThemeSettings(),
      );

      final restored = (await storage.getPlaylists()).single;
      expect(restored.offlineSongIds, {offline.id});
      expect(restored.isDownloaded, isFalse); // one of the two is online-only

      // Deleting the playlist takes its audio with it, as it does when the
      // download was made in this install.
      expect(await storage.deletePlaylist('p1'), isTrue);
      expect(await storage.getDownloadedSongs(), isEmpty);
    });

    test('a fully downloaded playlist restores as downloaded', () async {
      final storage = StorageService();
      await storage.addDownloadedSong(song);
      final playlist = Playlist(
        id: 'p2',
        name: 'All Offline',
        createdAt: DateTime.utc(2026, 1, 1),
        songs: [song],
      );

      await BackupService.instance.apply(
        BackupData(playlists: [playlist]),
        theme: ThemeSettings(),
      );

      final restored = (await storage.getPlaylists()).single;
      expect(restored.isDownloaded, isTrue);
      expect(restored.offlineSongIds, {song.id});
    });

    test('a restore on a phone with no downloads stays online-only', () async {
      final storage = StorageService();
      final playlist = Playlist(
        id: 'p3',
        name: 'New Phone',
        createdAt: DateTime.utc(2026, 1, 1),
        songs: [song],
      );

      await BackupService.instance.apply(
        BackupData(playlists: [playlist]),
        theme: ThemeSettings(),
      );

      final restored = (await storage.getPlaylists()).single;
      expect(restored.offlineSongIds, isEmpty);
      expect(restored.isDownloaded, isFalse);
    });
  });

  group('export', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('an absent platform bridge reads as unsupported, not as a failure',
        () async {
      final result = await BackupService.instance.export(
        name: 'Ravi',
        theme: ThemeSettings(),
        glass: null,
        videoMode: false,
        language: 'all',
        genres: const {},
        artists: const {},
      );

      // Tests run on the host VM, so the Android channel does not exist. The
      // user-facing message depends on this being its own outcome.
      expect(result.outcome, ExportOutcome.unsupported);
      expect(result.fileName, isNull);
    });
  });
}
