import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Playlist;
import '../models/artist.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/video_stats.dart';
import 'playlist_parser.dart';
import 'ytmusic_search.dart';

/// Metadata facade: search, related, playlists, trending.
/// NOTE: audio streams are NOT resolved here. All stream resolution,
/// ranking, downloading, and fallback live behind [MediaResolver]
/// implementations in lib/media/providers/.
/// If YouTube changes InnerTube tomorrow, only YouTubeProvider changes.
class YouTubeService {
  static const _timeout = Duration(seconds: 35);
  final YoutubeExplode _yt = YoutubeExplode();
  final PlaylistParser _parser = PlaylistParser();
  final YouTubeMusicSearch _ytm = YouTubeMusicSearch();

  Song _toSong(Video video) {
    return Song(
      id: video.id.value,
      title: video.title,
      artist: video.author,
      thumbnailUrl: video.thumbnails.mediumResUrl,
      duration: video.duration ?? Duration.zero,
      videoId: video.id.value,
      channel: video.author,
    );
  }

  Future<List<Song>> search(String query, {int limit = 20}) async {
    // Preferred path: YouTube Music's "Songs" catalogue. It classifies
    // results, so it excludes the music videos / lyric uploads / covers that
    // plain youtube.com search mixes in. Falls back to legacy YouTube search
    // only when the query has no song entry (some regional/indie tracks exist
    // only as videos) or YTMusic is unreachable.
    try {
      final songs = await _ytm.searchSongs(query, limit: limit);
      if (songs.isNotEmpty) return songs;
    } catch (_) {
      // Fall through to the plain YouTube search below.
    }
    return _legacySearch(query, limit: limit);
  }

  /// Union of YouTube Music "Songs" and plain YouTube video results, for the
  /// explicit Search tab. Keeps user uploads (slowed/reverb, remix, lyric,
  /// covers) that catalogue-only [search] never returns. Callers still screen
  /// out trailers/movies/long-form via `SongFilter.applySearch`.
  ///
  /// One source failing must not blank the other: only when BOTH throw is the
  /// error surfaced.
  Future<List<Song>> searchAll(String query, {int limit = 25}) async {
    Object? firstError;
    var anySourceOk = false;
    final songs = <Song>[];
    final videos = <Song>[];

    Future<void> run(
        Future<List<Song>> Function() fetch, List<Song> sink) async {
      try {
        sink.addAll(await fetch());
        anySourceOk = true;
      } catch (e) {
        firstError ??= e;
      }
    }

    await Future.wait([
      run(() => _ytm.searchSongs(query, limit: limit), songs),
      run(() => _legacySearch(query, limit: limit), videos),
    ]);
    if (!anySourceOk) throw firstError ?? Exception('Search failed');
    return mergeResults(songs, videos, cap: limit * 2);
  }

  /// Merges catalogue songs with video results, keeping first occurrence by
  /// video id and collapsing the same track (normalized title + artist, so
  /// "Artist" and "Artist - Topic" match). Distinct uploads such as
  /// "Song (Slowed + Reverb)" keep distinct keys. Pure; unit-tested.
  static List<Song> mergeResults(
    List<Song> catalogue,
    List<Song> videos, {
    int cap = 50,
  }) {
    final out = <Song>[];
    final seenVideo = <String>{};
    final seenTrack = <String>{};
    for (final s in [...catalogue, ...videos]) {
      final vid = s.videoId ?? s.id;
      if (!seenVideo.add(vid)) continue;
      final key = '${_searchKey(s.title)}|${_searchKey(s.artist)}';
      if (!seenTrack.add(key)) continue;
      out.add(s);
      if (out.length >= cap) break;
    }
    return out;
  }

  /// Lowercase, punctuation/space-stripped, with trailing channel noise
  /// ("- Topic", "VEVO", "Official") removed so a catalogue entry and its
  /// upload collapse to one key.
  static String _searchKey(String value) {
    final v = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return v.replaceAll(RegExp(r'(topic|vevo|official)$'), '');
  }

  /// Artist page for a plain artist *name* ([Song.artist] is only a string).
  /// Resolves the YouTube Music channel and reads songs + albums/singles.
  /// When the artist cannot be resolved (unknown, offline, composite name),
  /// falls back to a plain song search so the screen still has content.
  Future<ArtistPage> artistByName(String name,
      {String? fallbackThumbnail}) async {
    final clean = name.trim();
    try {
      final id = await _ytm.resolveArtistId(clean);
      if (id != null) {
        final page = await _ytm.browseArtist(id);
        if (!page.isEmpty) {
          var songs = page.songs;
          final moreId = page.songsBrowseId;
          if (moreId != null) {
            try {
              final all = await _ytm.browseAlbum(moreId);
              if (all.length > songs.length) songs = all;
            } catch (_) {
              // Keep the preview songs when the full list cannot be read.
            }
          }
          return ArtistPage(
            name: page.name.isEmpty ? clean : page.name,
            imageUrl: page.imageUrl ?? fallbackThumbnail,
            songs: songs,
            albums: page.albums,
          );
        }
      }
    } catch (_) {
      // Fall through to the plain song search below.
    }
    final songs = await search(clean, limit: 25);
    return ArtistPage(name: clean, imageUrl: fallbackThumbnail, songs: songs);
  }

  /// Track list for one album/single browseId returned by [artistByName].
  Future<List<Song>> albumSongs(String browseId) => _ytm.browseAlbum(browseId);

  Future<List<Song>> _legacySearch(String query, {int limit = 20}) async {
    // Uses searchContent (raw SearchResult union) instead of search():
    // search() eagerly maps every item to Video and throws the whole
    // batch away on one unparsable renderer (live/"Streamed" results).
    // Filtering to SearchVideo with per-item guards keeps one bad item
    // from failing the whole search.
    try {
      final content = await _yt.search
          .searchContent(query, filter: TypeFilters.video)
          .timeout(_timeout);
      final songs = <Song>[];
      for (final item in content) {
        if (songs.length >= limit) break;
        if (item is! SearchVideo) continue;
        try {
          songs.add(songFromSearchVideo(item));
        } catch (_) {
          continue;
        }
      }
      return songs;
    } catch (e) {
      throw Exception('Search failed: $e');
    }
  }

  /// Maps raw search results defensively. Static for unit tests.
  static Song songFromSearchVideo(SearchVideo v) {
    String thumb = 'https://i.ytimg.com/vi/${v.id.value}/hqdefault.jpg';
    try {
      if (v.thumbnails.isNotEmpty) {
        final best = v.thumbnails
            .reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b);
        thumb = best.url.toString();
      }
    } catch (_) {}
    return Song(
      id: v.id.value,
      title: v.title,
      artist: v.author,
      thumbnailUrl: thumb,
      duration: parseDurationString(v.duration),
      videoId: v.id.value,
      channel: v.author,
    );
  }

  /// Parses "HH:MM:SS" / "MM:SS". Anything else (live, empty) → zero.
  /// Static for unit tests.
  static Duration parseDurationString(String text) {
    try {
      final parts = text.split(':').map((p) => int.parse(p.trim())).toList();
      if (parts.length == 3) {
        return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
      }
      if (parts.length == 2) {
        return Duration(minutes: parts[0], seconds: parts[1]);
      }
      if (parts.length == 1) return Duration(seconds: parts[0]);
    } catch (_) {}
    return Duration.zero;
  }

  /// Read-only engagement for one exact video. Returns null when the lookup
  /// fails (network, rate limit, gone) so callers can show "N/A" instead of
  /// inventing numbers. Dislikes are usually null (YouTube removed them) —
  /// see [VideoStats].
  Future<VideoStats?> getVideoStats(String videoId) async {
    try {
      final video = await _yt.videos.get(VideoId(videoId)).timeout(_timeout);
      final engagement = video.engagement;
      return VideoStats(
        likes: engagement.likeCount,
        dislikes: engagement.dislikeCount,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<Song>> getRelatedVideos(String videoId, {int limit = 15}) async {
    try {
      final video = await _yt.videos.get(VideoId(videoId)).timeout(_timeout);
      final related =
          await _yt.videos.getRelatedVideos(video).timeout(_timeout);

      if (related == null) return [];
      return related.take(limit).map(_toSong).toList();
    } catch (e) {
      return [];
    }
  }

  Future<Playlist> getPlaylist(String playlistId) async {
    // Metadata via library (still works), songs via custom parser because
    // YouTube replaced playlistVideoRenderer with lockupViewModel items.
    String name = 'Imported Playlist';
    String? description;
    try {
      final meta = await _yt.playlists.get(playlistId).timeout(_timeout);
      name = meta.title;
      description = meta.description;
    } catch (_) {
      // Keep defaults, songs matter most.
    }

    List<Song> songs = [];
    try {
      songs = await _parser.fetchVideos(playlistId);
    } catch (e) {
      throw Exception('Failed to read playlist songs: $e');
    }
    // Playlists keep every song the user imported. The global language and
    // duration rules govern discovery (search, trending, recommendations),
    // not an explicit import — filtering here would drop songs from the
    // playlist.

    if (songs.isEmpty) {
      throw Exception('No playable songs found in this playlist');
    }

    return Playlist(
      id: playlistId,
      name: name,
      description: description,
      thumbnailUrl: songs.first.thumbnailUrl,
      songs: songs,
      createdAt: DateTime.now(),
      source: 'youtube',
    );
  }

  void dispose() {
    _ytm.dispose();
    _yt.close();
  }
}
