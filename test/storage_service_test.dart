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

    await storage.removeRecentEntries([songFor('b')], allCopies: true);
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['c', 'a']);

    // Unknown id is a no-op, not a wipe.
    await storage.removeRecentEntries([songFor('missing')], allCopies: true);
    expect((await storage.getRecentlyPlayed()).length, 2);

    await storage.clearRecentlyPlayed();
    expect(await storage.getRecentlyPlayed(), isEmpty);
  });

  test('recent history collapses only consecutive repeats', () async {
    final storage = StorageService();

    // Loop replay -> one entry.
    await storage.addToRecentlyPlayed(songFor('a'));
    await storage.addToRecentlyPlayed(songFor('a'));
    await storage.addToRecentlyPlayed(songFor('a'));
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['a']);

    // A,B,A keeps both A's (newest first).
    await storage.addToRecentlyPlayed(songFor('b'));
    await storage.addToRecentlyPlayed(songFor('a'));
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['a', 'b', 'a']);

    // A,B,C,A -> newest first A,C,B,A.
    await storage.clearRecentlyPlayed();
    for (final id in ['a', 'b', 'c', 'a']) {
      await storage.addToRecentlyPlayed(songFor(id));
    }
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['a', 'c', 'b', 'a']);
  });

  // Regression: download completed but the UI spun forever because
  // addSongToDownloadedPlaylist nested serialized storage calls
  // (addSongToDownloadedPlaylist -> ensureDownloadedPlaylist ->
  // savePlaylist) and the non-reentrant write queue deadlocked.
  test('adding a downloaded song completes and persists', () async {
    final storage = StorageService();
    final song = songFor('dl1');

    await storage.addDownloadedSong(song);
    await storage
        .addSongToDownloadedPlaylist(song)
        .timeout(const Duration(seconds: 5));

    final downloaded = await storage.getDownloadedSongs();
    expect(downloaded.any((s) => s.id == song.id), isTrue);
    final downloadedPl = (await storage.getPlaylists())
        .firstWhere((p) => p.id == StorageService.downloadedPlaylistId);
    expect(downloadedPl.songs.any((s) => s.id == song.id), isTrue);
  });

  test('removing a downloaded song completes and cleans up', () async {
    final storage = StorageService();
    final song = songFor('dl2');
    await storage.addDownloadedSong(song);
    await storage
        .addSongToDownloadedPlaylist(song)
        .timeout(const Duration(seconds: 5));

    await storage
        .removeSongFromDownloadedPlaylist(song.id)
        .timeout(const Duration(seconds: 5));
    expect(await storage.getDownloadedSongs(), isEmpty);
  });

  test('recent history: delete only selected copies vs all copies', () async {
    final storage = StorageService();
    for (final id in ['a', 'b', 'a']) {
      await storage.addToRecentlyPlayed(songFor(id));
    }
    // Newest first: [a, b, a].
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['a', 'b', 'a']);

    // Drop ONE occurrence of 'a'.
    await storage.removeRecentEntries([songFor('a')], allCopies: false);
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['b', 'a']);

    // Drop every remaining occurrence of 'a'.
    await storage.removeRecentEntries([songFor('a')], allCopies: true);
    expect((await storage.getRecentlyPlayed()).map((s) => s.id).toList(),
        ['b']);
  });

  // Offline management: removing a download must clear the global list, every
  // playlist's offline set and the hidden system playlist in one shot.
  test('removeDownloadedSong clears global list, playlists and system list',
      () async {
    final storage = StorageService();
    final song = songFor('dlx');
    await storage.addDownloadedSong(song);
    await storage.addSongToDownloadedPlaylist(song);
    await storage.savePlaylist(Playlist(
      id: 'p_dl',
      name: 'Downloaded Mix',
      songs: [song],
      createdAt: DateTime.now(),
      downloadedSongIds: {song.id},
      isDownloaded: true,
      isSystemManaged: true,
    ));

    await storage.removeDownloadedSong(song.id);

    expect(await storage.getDownloadedSongs(), isEmpty);
    final playlists = await storage.getPlaylists();
    for (final p in playlists) {
      expect(p.downloadedSongIds.contains(song.id), isFalse);
    }
    final sys = playlists
        .firstWhere((p) => p.id == StorageService.downloadedPlaylistId);
    expect(sys.songs.any((s) => s.id == song.id), isFalse);
    final user = playlists.firstWhere((p) => p.id == 'p_dl');
    expect(user.songs.any((s) => s.id == song.id), isTrue,
        reason: 'online copy in a user playlist is preserved');
  });

  test('removeSongAndDownload drops the song from a playlist and downloads',
      () async {
    final storage = StorageService();
    final song = songFor('rd1');
    await storage.addDownloadedSong(song);
    await storage.savePlaylist(Playlist(
      id: 'p_rd',
      name: 'Mix',
      songs: [song, songFor('keep')],
      createdAt: DateTime.now(),
      downloadedSongIds: {song.id},
      isSystemManaged: true,
    ));

    await storage.removeSongAndDownload('p_rd', song.id);

    final updated =
        (await storage.getPlaylists()).firstWhere((p) => p.id == 'p_rd');
    expect(updated.songs.any((s) => s.id == song.id), isFalse);
    expect(updated.downloadedSongIds.contains(song.id), isFalse);
    expect(await storage.getDownloadedSongs(), isEmpty);
  });

  test('addSongToPlaylist edits a downloaded playlist but not the system one',
      () async {
    final storage = StorageService();
    final dl = songFor('dl3');
    await storage.addDownloadedSong(dl);
    await storage.savePlaylist(Playlist(
      id: 'p_edit',
      name: 'Mix',
      songs: [dl],
      createdAt: DateTime.now(),
      downloadedSongIds: {dl.id},
      isDownloaded: true,
      isSystemManaged: true,
    ));

    final newSong = songFor('new3');
    await storage.addSongToPlaylist('p_edit', newSong);

    final updated =
        (await storage.getPlaylists()).firstWhere((p) => p.id == 'p_edit');
    expect(updated.songs.any((s) => s.id == newSong.id), isTrue);
    expect(updated.isDownloaded, isFalse,
        reason: 'adding an online-only song clears the fully-downloaded flag');
    expect(updated.downloadedSongIds.contains(dl.id), isTrue);

    // The system playlist is managed by downloads, never manual adds.
    await storage.addSongToDownloadedPlaylist(songFor('sysseed'));
    await storage.addSongToPlaylist(
        StorageService.downloadedPlaylistId, songFor('nope'));
    final sys = (await storage.getPlaylists())
        .firstWhere((p) => p.id == StorageService.downloadedPlaylistId);
    expect(sys.songs.any((s) => s.id == 'nope'), isFalse);
  });

  test('renamePlaylist changes only the name', () async {
    final storage = StorageService();
    await storage.savePlaylist(playlistFor('p_rename'));
    await storage.renamePlaylist('p_rename', 'Road Trip');

    final updated =
        (await storage.getPlaylists()).firstWhere((p) => p.id == 'p_rename');
    expect(updated.name, 'Road Trip');
    expect(updated.songs, isEmpty);

    // Unknown id is a no-op, not a crash.
    await storage.renamePlaylist('missing', 'Nope');
    expect((await storage.getPlaylists()).length, 1);
  });
}
