import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:atlas_music/models/playlist.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/storage_service.dart';

Song songFor(String id) => Song(
      id: id,
      title: 'Song $id',
      artist: 'Artist $id',
      thumbnailUrl: '',
      duration: const Duration(seconds: 180),
    );

Playlist playlistFor(String id) => Playlist(
      id: id,
      name: 'Playlist $id',
      songs: const [],
      createdAt: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // F7 regression: concurrent get -> mutate -> set used to be able to lose
  // updates (last writer wins). Every mutator must now serialise.
  test('concurrent recordListen calls do not lose updates', () async {
    final storage = StorageService();
    const n = 25;
    await Future.wait([
      for (var i = 0; i < n; i++)
        storage.recordListen(
          songFor('s$i'),
          listenedMs: 1000,
          skipped: false,
        ),
    ]);

    final stats = await storage.getListeningStats();
    expect(stats.length, n, reason: 'every song must have a stats entry');
    for (var i = 0; i < n; i++) {
      expect(stats['s$i']?['playCount'], 1);
    }
  });

  test('concurrent toggles of the same song resolve deterministically',
      () async {
    final storage = StorageService();
    final song = songFor('like');
    // 5 toggles: odd number => liked.
    await Future.wait([
      for (var i = 0; i < 5; i++) storage.toggleLikedSong(song),
    ]);
    expect(await storage.isSongLiked(song.id), isTrue);
  });

  test('concurrent playlist writes keep every playlist', () async {
    final storage = StorageService();
    const n = 10;
    await Future.wait([
      for (var i = 0; i < n; i++) storage.savePlaylist(playlistFor('p$i')),
    ]);
    final playlists = await storage.getPlaylists();
    expect(playlists.length, n);
  });

  test('recent history: remove one song, clear all', () async {
    final storage = StorageService();
    await storage.addToRecentlyPlayed(songFor('a'));
    await storage.addToRecentlyPlayed(songFor('b'));
    await storage.addToRecentlyPlayed(songFor('c'));

    // Newest first.
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['c', 'b', 'a']);

    await storage.removeFromRecentlyPlayed('b');
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['c', 'a']);

    // Unknown id is a no-op, not a wipe.
    await storage.removeFromRecentlyPlayed('missing');
    expect((await storage.getRecentlyPlayed()).length, 2);

    await storage.clearRecentlyPlayed();
    expect(await storage.getRecentlyPlayed(), isEmpty);
  });
}
