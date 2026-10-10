import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';
import '../models/song.dart';

class StorageService extends ChangeNotifier {
  static final StorageService instance = StorageService._internal();
  StorageService._internal();
  factory StorageService() => instance;
  static const String _playlistsKey = 'playlists';
  static const String _likedSongsKey = 'liked_songs';
  static const String _recentlyPlayedKey = 'recently_played';
  static const String _listeningStatsKey = 'listening_stats';
  static const String _topArtistsKey = 'top_artists';
  static const String _searchHistoryKey = 'search_history';
  static const String _downloadedSongsKey = 'downloaded_songs';
  static const String _playbackSessionKey = 'playback_session';
  static const String downloadedPlaylistId = 'downloaded_music';

  // Every mutation is get -> mutate -> set against SharedPreferences with
  // no serialisation, so concurrent writers (rapid skipping fires
  // recordListen per track change) silently lose updates. Route every
  // mutator through this tail future so writes run one at a time. The tail
  // is kept resolved, so it never retains an error and never grows.
  //
  // Reentrant: a serialized action may await another serialized method. The
  // first (outer) call owns the queue; a nested call sees the zone marker and
  // runs inline instead of deadlocking behind the action awaiting it.
  static final Object _writeZoneKey = Object();
  Future<void> _writeTail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    if (Zone.current[_writeZoneKey] == true) return action();
    final result = _writeTail.then(
      (_) => runZoned(action, zoneValues: {_writeZoneKey: true}),
    );
    _writeTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Decodes a JSON-backed preference. A truncated/corrupt value would
  /// otherwise throw on every read for the rest of the install, bricking
  /// Home, Library and Profile with no recovery path. Corrupt data is
  /// treated as absent (and the key cleared by the caller's next write).
  static T? _safeDecode<T>(String? raw) {
    if (raw == null) return null;
    try {
      return json.decode(raw) as T;
    } catch (_) {
      return null;
    }
  }

  // ── Playback session (mini-player restore) ──

  Future<Map<String, dynamic>?> getPlaybackSession() async {
    final prefs = await SharedPreferences.getInstance();
    return _safeDecode<Map<String, dynamic>>(
        prefs.getString(_playbackSessionKey));
  }

  Future<void> savePlaybackSession(Map<String, dynamic> session) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_playbackSessionKey, json.encode(session));
    });
  }

  Future<void> clearPlaybackSession() {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_playbackSessionKey);
    });
  }

  // ── Playlists ──

  Future<List<Playlist>> getPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_playlistsKey);
    final jsonList = _safeDecode<List<dynamic>>(jsonString);
    if (jsonList == null) return [];
    return jsonList.map((j) => Playlist.fromJson(j)).toList();
  }

  Future<void> savePlaylist(Playlist playlist) {
    return _serialized(() async {
      final playlists = await getPlaylists();
      final index = playlists.indexWhere((p) => p.id == playlist.id);
      if (index >= 0) {
        playlists[index] = playlist;
      } else {
        playlists.add(playlist);
      }
      final prefs = await SharedPreferences.getInstance();
      final jsonList = playlists.map((p) => p.toJson()).toList();
      await prefs.setString(_playlistsKey, json.encode(jsonList));
      notifyListeners();
    });
  }

  Future<void> deletePlaylist(String playlistId) {
    return _serialized(() async {
      final playlists = await getPlaylists();
      Playlist? target;
      for (final p in playlists) {
        if (p.id == playlistId) {
          target = p;
          break;
        }
      }
      if (target == null) return;
      // System Downloaded Music is managed separately.
      if (target.id == downloadedPlaylistId) return;
      // Protected while it still holds offline content. Must be cleared via
      // Offline Content first. Once downloadedSongIds is empty and
      // isDownloaded is false, it behaves normally again (deletable), even
      // if a stale isSystemManaged flag lingered from an older build.
      if (target.isDownloaded || target.downloadedSongIds.isNotEmpty) return;
      playlists.removeWhere((p) => p.id == playlistId);
      final prefs = await SharedPreferences.getInstance();
      final jsonList = playlists.map((p) => p.toJson()).toList();
      await prefs.setString(_playlistsKey, json.encode(jsonList));
      notifyListeners();
    });
  }

  Future<void> addSongToPlaylist(String playlistId, Song song) {
    return _serialized(() async {
      // Playlists are the user's explicit choice: any song can be added. The
      // global language/duration rules apply to discovery, not to playlists.
      final playlists = await getPlaylists();
      final idx = playlists.indexWhere((p) => p.id == playlistId);
      if (idx < 0) return;
      final p = playlists[idx];
      // The system Downloaded Music list is managed by downloads, not manually.
      if (p.id == downloadedPlaylistId) return;
      if (p.songs.any((s) => s.id == song.id)) return;
      // A user playlist that holds offline tracks is still editable: adding an
      // online-only song simply clears the "fully downloaded" flag.
      final songs = [...p.songs, song];
      final isDl = p.downloadedSongIds.isNotEmpty &&
          p.downloadedSongIds.length == songs.length;
      playlists[idx] = p.copyWith(songs: songs, isDownloaded: isDl);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _playlistsKey,
        json.encode(playlists.map((p) => p.toJson()).toList()),
      );
      notifyListeners();
    });
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) {
    return _serialized(() async {
      // System Downloaded Music has its own removal path that also cleans
      // the global downloaded list.
      if (playlistId == downloadedPlaylistId) {
        await removeSongFromDownloadedPlaylist(songId);
        return;
      }
      final playlists = await getPlaylists();
      final idx = playlists.indexWhere((p) => p.id == playlistId);
      if (idx < 0) return;
      final p = playlists[idx];
      // A downloaded song must go through [removeSongAndDownload] so the cache
      // and global list stay in sync. Online-only songs can be removed here
      // even when the playlist also holds offline tracks.
      if (p.downloadedSongIds.contains(songId)) return;
      final nextSongs = p.songs.where((s) => s.id != songId).toList();
      final isDl = p.downloadedSongIds.isNotEmpty &&
          p.downloadedSongIds.length == nextSongs.length;
      final sys = p.downloadedSongIds.isNotEmpty ? p.isSystemManaged : false;
      playlists[idx] = p.copyWith(
        songs: nextSongs,
        isDownloaded: isDl,
        isSystemManaged: sys,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _playlistsKey,
        json.encode(playlists.map((p) => p.toJson()).toList()),
      );
      notifyListeners();
    });
  }

  Future<void> updateCover(String playlistId, String? path) {
    return _serialized(() async {
      final playlists = await getPlaylists();
      final index = playlists.indexWhere((p) => p.id == playlistId);
      if (index < 0) return;
      playlists[index] = playlists[index].copyWith(coverPath: path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _playlistsKey,
        json.encode(playlists.map((p) => p.toJson()).toList()),
      );
    });
  }

  /// Renames a playlist. Caller validates a non-empty name.
  Future<void> renamePlaylist(String playlistId, String name) {
    return _serialized(() async {
      final playlists = await getPlaylists();
      final index = playlists.indexWhere((p) => p.id == playlistId);
      if (index < 0) return;
      playlists[index] = playlists[index].copyWith(name: name);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _playlistsKey,
        json.encode(playlists.map((p) => p.toJson()).toList()),
      );
      notifyListeners();
    });
  }

  // ── Liked songs ──

  Future<List<Song>> getLikedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_likedSongsKey);
    final jsonList = _safeDecode<List<dynamic>>(jsonString);
    if (jsonList == null) return [];
    return jsonList.map((j) => Song.fromJson(j)).toList();
  }

  Future<void> toggleLikedSong(Song song) {
    return _serialized(() async {
      final likedSongs = await getLikedSongs();
      final index = likedSongs.indexWhere((s) => s.id == song.id);
      if (index >= 0) {
        likedSongs.removeAt(index);
      } else {
        likedSongs.add(song);
      }
      final prefs = await SharedPreferences.getInstance();
      final jsonList = likedSongs.map((s) => s.toJson()).toList();
      await prefs.setString(_likedSongsKey, json.encode(jsonList));
      // Realtime: library liked rail + profile counts listen to storage.
      notifyListeners();
    });
  }

  Future<bool> isSongLiked(String songId) async {
    final likedSongs = await getLikedSongs();
    return likedSongs.any((s) => s.id == songId);
  }

  // ── Recently played ──

  Future<List<Song>> getRecentlyPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_recentlyPlayedKey);
    final jsonList = _safeDecode<List<dynamic>>(jsonString);
    if (jsonList == null) return [];
    return jsonList.map((j) => Song.fromJson(j)).toList();
  }

  Future<void> addToRecentlyPlayed(Song song) {
    return _serialized(() async {
      final recentlyPlayed = await getRecentlyPlayed();
      // Play-order history: collapse only CONSECUTIVE repeats.
      // A,A,A -> A. A,B,A -> A,B,A (both A's kept). A,B,C,A -> A,B,C,A.
      if (recentlyPlayed.isNotEmpty && recentlyPlayed.first.id == song.id) {
        return; // already the newest entry; no write, no notify
      }
      recentlyPlayed.insert(0, song);
      if (recentlyPlayed.length > 50) {
        recentlyPlayed.removeRange(50, recentlyPlayed.length);
      }
      final prefs = await SharedPreferences.getInstance();
      final jsonList = recentlyPlayed.map((s) => s.toJson()).toList();
      await prefs.setString(_recentlyPlayedKey, json.encode(jsonList));
      // Realtime: home rail, counts, and profile stats refresh on each play.
      notifyListeners();
    });
  }

  /// Deletes selected history entries in one serialized write.
  /// [allCopies] true  -> remove every entry whose id is selected.
  /// [allCopies] false -> drop exactly as many occurrences as are selected.
  /// Occurrences are indistinguishable, so dropping one copy is
  /// position-independent.
  Future<void> removeRecentEntries(List<Song> selected,
      {required bool allCopies}) {
    return _serialized(() async {
      final recentlyPlayed = await getRecentlyPlayed();
      final before = recentlyPlayed.length;
      if (allCopies) {
        final ids = selected.map((s) => s.id).toSet();
        recentlyPlayed.removeWhere((s) => ids.contains(s.id));
      } else {
        final counts = <String, int>{};
        for (final s in selected) {
          counts[s.id] = (counts[s.id] ?? 0) + 1;
        }
        counts.forEach((id, n) {
          recentlyPlayed.removeWhere((s) {
            if (n > 0 && s.id == id) {
              n--;
              return true;
            }
            return false;
          });
        });
      }
      if (recentlyPlayed.length == before) return;
      final prefs = await SharedPreferences.getInstance();
      final jsonList = recentlyPlayed.map((s) => s.toJson()).toList();
      await prefs.setString(_recentlyPlayedKey, json.encode(jsonList));
      notifyListeners();
    });
  }

  /// Wipes the whole listening history from this device. Listening stats
  /// (Quick Picks signals) are deliberately preserved.
  Future<void> clearRecentlyPlayed() {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_recentlyPlayedKey);
      notifyListeners();
    });
  }

  // ── Listening stats (for personalized recommendations) ──

  Future<Map<String, Map<String, dynamic>>> _getStats() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_listeningStatsKey);
    final decoded = _safeDecode<Map<String, dynamic>>(raw);
    if (decoded == null) return {};
    return decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
  }

  Future<void> _saveStats(Map<String, Map<String, dynamic>> stats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_listeningStatsKey, json.encode(stats));
  }

  /// Full listening stats for recommenders (Quick Picks): per song id →
  /// {playCount, skipCount, totalMs, lastPlayed, skipTimes?}.
  /// Public read-only snapshot; never mutated by callers.
  Future<Map<String, Map<String, dynamic>>> getListeningStats() async {
    return _getStats();
  }

  Future<void> recordListen(Song song,
      {required int listenedMs, required bool skipped}) {
    return _serialized(() async {
      final stats = await _getStats();
      final now = DateTime.now().millisecondsSinceEpoch;
      final entry = stats[song.id] ??
          {
            'playCount': 0,
            'skipCount': 0,
            'totalMs': 0,
            'lastPlayed': 0,
          };
      entry['playCount'] = (entry['playCount'] as int) + 1;
      entry['totalMs'] = (entry['totalMs'] as int) + listenedMs;
      entry['lastPlayed'] = now;
      if (skipped) {
        entry['skipCount'] = (entry['skipCount'] as int) + 1;
        // Skip timestamps power time-decayed skip penalties (Quick Picks):
        // recent repeated skips weigh strongly, >90d less than half, >1yr
        // effectively ignored. Capped so the blob never grows.
        final times =
            ((entry['skipTimes'] as List?) ?? []).whereType<int>().toList();
        times.add(now);
        entry['skipTimes'] =
            times.length > 20 ? times.sublist(times.length - 20) : times;
      }
      stats[song.id] = entry;
      await _saveStats(stats);

      if (song.artist.isNotEmpty) {
        final artists = await _getTopArtists();
        artists[song.artist] = (artists[song.artist] ?? 0) + 1;
        await _saveTopArtists(artists);
      }
    });
  }

  Future<Map<String, int>> _getTopArtists() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_topArtistsKey);
    final decoded = _safeDecode<Map<String, dynamic>>(raw);
    if (decoded == null) return {};
    return Map<String, int>.from(decoded);
  }

  Future<void> _saveTopArtists(Map<String, int> artists) async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = artists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = Map.fromEntries(sorted.take(30));
    await prefs.setString(_topArtistsKey, json.encode(top));
  }

  Future<List<String>> getTopArtists({int limit = 5}) async {
    final artists = await _getTopArtists();
    final sorted = artists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  Future<bool> hasEnoughHistory() async {
    final stats = await _getStats();
    int totalMs = 0;
    for (final v in stats.values) {
      totalMs += (v['totalMs'] as int? ?? 0);
    }
    return totalMs >= 5000;
  }

  Future<List<String>> getSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_searchHistoryKey);
    return list ?? [];
  }

  Future<void> addSearchQuery(String query) {
    return _serialized(() async {
      if (query.trim().isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_searchHistoryKey) ?? [];
      final q = query.trim();
      list.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
      list.insert(0, q);
      if (list.length > 20) list.removeRange(20, list.length);
      await prefs.setStringList(_searchHistoryKey, list);
    });
  }

  Future<void> clearSearchHistory() {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_searchHistoryKey);
    });
  }

  Future<List<Song>> getDownloadedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_downloadedSongsKey);
    final jsonList = _safeDecode<List<dynamic>>(jsonString);
    if (jsonList == null) return [];
    return jsonList
        .map((j) => Song.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<void> addDownloadedSong(Song song) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_downloadedSongsKey);
      final decoded = _safeDecode<List<dynamic>>(jsonString);
      final List<Song> list = decoded == null
          ? []
          : decoded
              .map((j) => Song.fromJson(j as Map<String, dynamic>))
              .toList();
      if (!list.any((s) => s.id == song.id)) {
        list.add(song);
        await prefs.setString(_downloadedSongsKey,
            json.encode(list.map((s) => s.toJson()).toList()));
      }
    });
  }

  /// Drops a song from the global downloaded list, every playlist's offline
  /// set, and the (hidden) system Downloaded Music playlist. Caller deletes
  /// the cached file.
  Future<void> _removeDownloadEverywhere(String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_downloadedSongsKey);
    final decoded = _safeDecode<List<dynamic>>(jsonString);
    if (decoded != null) {
      final List<Song> list = decoded
          .map((j) => Song.fromJson(j as Map<String, dynamic>))
          .toList();
      list.removeWhere((s) => s.id == songId);
      await prefs.setString(_downloadedSongsKey,
          json.encode(list.map((s) => s.toJson()).toList()));
    }
    // Also drop it from every playlist's offline set. Online copies in
    // playlist.songs are preserved. When a playlist's offline set becomes
    // empty it is unprotected so it behaves normally again (deletable).
    final playlists = await getPlaylists();
    bool changed = false;
    for (var i = 0; i < playlists.length; i++) {
      final p = playlists[i];
      final isSystem = p.id == downloadedPlaylistId;
      if (!p.downloadedSongIds.contains(songId) && !isSystem) continue;
      final nextIds = Set<String>.from(p.downloadedSongIds)..remove(songId);
      final nextSongs = isSystem
          ? p.songs.where((s) => s.id != songId).toList()
          : p.songs;
      final isDl = nextIds.isNotEmpty && nextIds.length == nextSongs.length;
      if (isSystem) {
        playlists[i] = p.copyWith(
          songs: nextSongs,
          isDownloaded: isDl,
          downloadedSongIds: nextIds,
        );
      } else if (nextIds.isEmpty) {
        playlists[i] = p.copyWith(
          isDownloaded: false,
          downloadedSongIds: nextIds,
          isSystemManaged: false,
        );
      } else {
        playlists[i] = p.copyWith(
          isDownloaded: isDl,
          downloadedSongIds: nextIds,
        );
      }
      changed = true;
    }
    if (changed) {
      await prefs.setString(_playlistsKey,
          json.encode(playlists.map((p) => p.toJson()).toList()));
    }
    notifyListeners();
  }

  Future<void> removeDownloadedSong(String songId) {
    return _serialized(() => _removeDownloadEverywhere(songId));
  }

  /// Removes a song from [playlistId] AND deletes its download everywhere.
  /// Used when deleting a downloaded track from a playlist; caller deletes
  /// the cached file.
  Future<void> removeSongAndDownload(String playlistId, String songId) {
    return _serialized(() async {
      final playlists = await getPlaylists();
      final idx = playlists.indexWhere((p) => p.id == playlistId);
      if (idx >= 0) {
        final p = playlists[idx];
        final nextSongs = p.songs.where((s) => s.id != songId).toList();
        final nextIds = Set<String>.from(p.downloadedSongIds)..remove(songId);
        final isDl = nextIds.isNotEmpty && nextIds.length == nextSongs.length;
        playlists[idx] = p.copyWith(
          songs: nextSongs,
          downloadedSongIds: nextIds,
          isDownloaded: isDl,
          isSystemManaged: nextIds.isNotEmpty ? p.isSystemManaged : false,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_playlistsKey,
            json.encode(playlists.map((p) => p.toJson()).toList()));
      }
      await removeDownloadedSong(songId);
    });
  }

  Future<Playlist> ensureDownloadedPlaylist() {
    return _serialized(() async {
      final playlists = await getPlaylists();
      final pl = playlists.firstWhere(
        (p) => p.id == downloadedPlaylistId,
        orElse: () => Playlist(
          id: downloadedPlaylistId,
          name: 'Downloaded Music',
          songs: [],
          createdAt: DateTime.now(),
          source: 'system',
          isSystemManaged: true,
        ),
      );
      if (!playlists.any((p) => p.id == downloadedPlaylistId)) {
        await savePlaylist(pl);
      }
      return pl;
    });
  }

  Future<void> addSongToDownloadedPlaylist(Song song) {
    return _serialized(() async {
      await ensureDownloadedPlaylist();
      final playlists = await getPlaylists();
      final idx = playlists.indexWhere((p) => p.id == downloadedPlaylistId);
      if (idx >= 0) {
        final existing = playlists[idx];
        if (!existing.songs.any((s) => s.id == song.id)) {
          playlists[idx] = existing.copyWith(songs: [...existing.songs, song]);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_playlistsKey,
              json.encode(playlists.map((p) => p.toJson()).toList()));
          notifyListeners();
        }
      }
    });
  }

  Future<void> removeSongFromDownloadedPlaylist(String songId) {
    return _serialized(() async {
      final playlists = await getPlaylists();
      final idx = playlists.indexWhere((p) => p.id == downloadedPlaylistId);
      if (idx >= 0) {
        final pl = playlists[idx];
        playlists[idx] =
            pl.copyWith(songs: pl.songs.where((s) => s.id != songId).toList());
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_playlistsKey,
            json.encode(playlists.map((p) => p.toJson()).toList()));
      }
      // Keep global downloaded list in sync, but preserve it if another
      // downloaded playlist still references this song offline.
      final stillNeeded =
          playlists.any((pl) => pl.downloadedSongIds.contains(songId));
      if (!stillNeeded) {
        final prefs = await SharedPreferences.getInstance();
        final jsonString = prefs.getString(_downloadedSongsKey);
        final decoded = _safeDecode<List<dynamic>>(jsonString);
        if (decoded != null) {
          final List<Song> list = decoded
              .map((j) => Song.fromJson(j as Map<String, dynamic>))
              .toList();
          final before = list.length;
          list.removeWhere((s) => s.id == songId);
          if (list.length != before) {
            await prefs.setString(_downloadedSongsKey,
                json.encode(list.map((s) => s.toJson()).toList()));
          }
        }
      }
      notifyListeners();
    });
  }

}

