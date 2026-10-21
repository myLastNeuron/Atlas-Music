import 'dart:math';

import '../models/song.dart';
import 'song_filter.dart';
import 'user_prefs.dart';

/// Personalized ranking — pure logic, no plugins, unit-tested.
///
/// The signal is deliberately small and honest. What the engine can actually
/// see on this device (no audio-feature API, no backend): YouTube
/// titles/artists/channels, YouTube Music's radio order, listening stats
/// (plays, completion, time-decayed skips), the recent session, likes, the
/// user's top/selected artists, and explicit "not interested" marks.
///
/// Predictable by construction: the same candidates + the same stored state
/// produce the same order (score, then title, then id), and every pick's
/// [QuickPick.reason] names the signal that ranked it.
///
// ponytail: no per-song genre or audio features exist here — YouTube
// Music's radio order stands in for genre similarity. Add a metadata API
// (Deezer album genre / MusicBrainz tags) only if radio coverage proves thin.
class QuickPick {
  final Song song;
  final double score;
  final String reason;
  const QuickPick({
    required this.song,
    required this.score,
    required this.reason,
  });
}

class QuickPicksEngine {
  static const int defaultMaxPerArtist = 2;
  static const int recentMinutesExclusion = 60;

  // Score weights. They sum to just under 1; penalties are subtracted.
  static const double _wSessionArtist = 0.32;
  static const double _wSource = 0.20; // YouTube radio position
  static const double _wArtistAffinity = 0.16; // top-artists order
  static const double _wLiked = 0.14;
  static const double _wCompletion = 0.10;
  static const double _wSelected = 0.06;
  static const double _maxSkipPenalty = 0.40;
  static const double _skipUnit = 0.10;
  static const double _maxDislikePenalty = 0.24;
  static const double _dislikeUnit = 0.08;

  /// Rank [candidates] for the session led by [recent] (most-recent-first,
  /// [recent.first] is the seed). Returns at most [count] picks, strongest
  /// first, capped at [maxPerArtist] per artist. Never throws.
  ///
  /// [sourceScores] maps a video id to a 0..1 similarity (YouTube Music's
  /// radio order). [notInterested] is the stored song-id → {at, artist}
  /// map: those songs are excluded and their artist is down-weighted.
  static List<QuickPick> rank({
    required List<Song> recent,
    required List<Song> candidates,
    Map<String, Map<String, dynamic>> stats = const {},
    Map<String, Map<String, dynamic>> notInterested = const {},
    Map<String, double> sourceScores = const {},
    List<String> topArtists = const [],
    Set<String> likedIds = const {},
    Set<String> queueIds = const {},
    MusicLanguage userLanguage = MusicLanguage.all,
    List<String> selectedArtists = const [],
    int count = 10,
    int maxPerArtist = defaultMaxPerArtist,
    bool requirePersonalSignal = false,
  }) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final session = recent.take(5).toList();
      final seed = session.isNotEmpty ? session.first : null;
      final recentIds = session.map((s) => s.id).toSet();
      final sessionArtists = <String>{
        for (final s in session) ..._tokens(s.artist),
      };
      final dislikedArtists = _dislikedArtists(notInterested, now);

      final seenVideo = <String>{};
      final seenTrack = <String>{};
      final scored = <_Scored>[];
      for (final c in candidates) {
        final vid = c.videoId ?? c.id;
        if (!seenVideo.add(vid)) continue; // duplicate uploads
        final sig = '${_normTitle(c.title)}|${_normTitle(c.artist)}';
        if (!seenTrack.add(sig)) continue; // duplicate versions
        if (recentIds.contains(c.id)) continue; // already in session
        if (queueIds.contains(c.id) || queueIds.contains(vid)) continue;
        if (notInterested.containsKey(c.id) || notInterested.containsKey(vid)) {
          continue; // explicitly dismissed
        }
        // GLOBAL rules hold inside the engine too, never just upstream.
        if (!SongFilter.inDurationWindow(c)) continue;
        if (c.duration.inSeconds <= 0) continue; // need verified length
        if (SongFilter.isMusicVideo(c)) continue;
        if (!SongFilter.matchesLanguage(c, userLanguage)) continue;

        final st = stats[c.id];
        final last = (st?['lastPlayed'] as int?) ?? 0;
        if (last > 0 && now - last < recentMinutesExclusion * 60 * 1000) {
          continue; // played within the last 60 minutes
        }

        final artistOverlap =
            _tokens(c.artist).intersection(sessionArtists).isNotEmpty;
        final liked = likedIds.contains(c.id);
        final affinity = _artistAffinity(c.artist, topArtists);
        final inSelected = _artistInList(c.artist, selectedArtists);
        final loved = _completion(st, c);
        final fromRadio = sourceScores.containsKey(vid);
        if (requirePersonalSignal &&
            !(artistOverlap ||
                liked ||
                affinity > 0 ||
                inSelected ||
                fromRadio ||
                (st?['playCount'] as int? ?? 0) > 0)) {
          continue;
        }

        var score = 0.0;
        if (artistOverlap) score += _wSessionArtist;
        score += _wSource * (sourceScores[vid] ?? sourceScores[c.id] ?? 0.0);
        score += _wArtistAffinity * affinity;
        if (liked) score += _wLiked;
        score += _wCompletion * loved;
        if (inSelected) score += _wSelected;
        score -= _skipPenalty(st, now);
        score -= _dislikeUnit * (dislikedArtists[_artistKey(c.artist)] ?? 0);
        score = score.clamp(-0.8, 1.0);

        scored.add(_Scored(c, score));
      }

      // Deterministic: identical state must produce an identical list, even
      // when the network returns candidates in a different order.
      scored.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byTitle =
            a.song.title.toLowerCase().compareTo(b.song.title.toLowerCase());
        if (byTitle != 0) return byTitle;
        return a.song.id.compareTo(b.song.id);
      });
      if (scored.isEmpty) return const [];

      // Diversity: cap repeats per artist.
      final perArtist = <String, int>{};
      final picks = <_Scored>[];
      for (final s in scored) {
        if (picks.length >= count) break;
        final key = s.song.artist.toLowerCase().trim();
        final n = perArtist[key] ?? 0;
        if (n >= maxPerArtist) continue;
        perArtist[key] = n + 1;
        picks.add(s);
      }

      return picks
          .map((s) => QuickPick(
                song: s.song,
                score: s.score,
                reason: _reasonFor(
                  s.song,
                  seed: seed,
                  session: session,
                  topArtists: topArtists,
                  likedIds: likedIds,
                  stats: stats,
                  sourceScores: sourceScores,
                ),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Position in [topArtists] as a 0..1 affinity (strongest artist = 1).
  static double _artistAffinity(String artist, List<String> topArtists) {
    if (topArtists.isEmpty) return 0;
    final key = _artistKey(artist);
    if (key.isEmpty) return 0;
    for (var i = 0; i < topArtists.length; i++) {
      if (_artistKey(topArtists[i]) == key) {
        return 1 - i / topArtists.length;
      }
    }
    return 0;
  }

  /// Average completion of stored listens: 0..1. A song played to the end
  /// once and never skipped is a stronger signal than one skipped halfway.
  static double _completion(Map<String, dynamic>? st, Song song) {
    if (st == null) return 0;
    final plays = (st['playCount'] as int?) ?? 0;
    final totalMs = (st['totalMs'] as int?) ?? 0;
    final durationMs = song.duration.inMilliseconds;
    if (plays <= 0 || totalMs <= 0 || durationMs <= 0) return 0;
    return (totalMs / (plays * durationMs)).clamp(0.0, 1.0);
  }

  /// Time-decayed skip weight (90-day half-life), capped. Falls back to the
  /// plain skip count for old builds that stored no timestamps.
  static double _skipPenalty(Map<String, dynamic>? st, int now) {
    if (st == null) return 0;
    final times = (st['skipTimes'] as List?)?.whereType<int>().toList() ?? [];
    var weight = 0.0;
    if (times.isEmpty) {
      weight = ((st['skipCount'] as int?) ?? 0) * 0.5;
    } else {
      weight = _decayed(times, now, 90);
    }
    return min(_maxSkipPenalty, weight * _skipUnit);
  }

  /// Decayed count of "not interested" marks per artist (180-day half-life).
  static Map<String, double> _dislikedArtists(
      Map<String, Map<String, dynamic>> notInterested, int now) {
    final out = <String, double>{};
    for (final entry in notInterested.values) {
      final key = _artistKey((entry['artist'] as String?) ?? '');
      if (key.isEmpty) continue;
      final at = (entry['at'] as int?) ?? 0;
      final weight = at <= 0 ? 1.0 : _decay(at, now, 180);
      out[key] =
          min(_maxDislikePenalty / _dislikeUnit, (out[key] ?? 0) + weight);
    }
    return out;
  }

  static double _decayed(List<int> times, int now, double halfLifeDays) {
    var sum = 0.0;
    for (final t in times) {
      sum += t <= 0 ? 1.0 : _decay(t, now, halfLifeDays);
    }
    return sum;
  }

  static double _decay(int at, int now, double halfLifeDays) {
    final age = now - at;
    if (age <= 0) return 1.0;
    return pow(0.5, age / (halfLifeDays * 86400000)).toDouble();
  }

  static String _artistKey(String artist) {
    final tokens = _tokens(artist).toList()..sort();
    return tokens.join(' ');
  }

  static bool _artistInList(String artist, List<String> list) {
    final a = _tokens(artist);
    if (a.isEmpty) return false;
    for (final e in list) {
      final t = _tokens(e);
      if (t.isEmpty) continue;
      if (a.join(' ') == t.join(' ')) return true;
      final shared = a.intersection(t).length;
      final shorterLength = a.length < t.length ? a.length : t.length;
      if (shared >= 2 && shared / shorterLength >= 0.75) {
        return true;
      }
    }
    return false;
  }

  static String _reasonFor(
    Song c, {
    required Song? seed,
    required List<Song> session,
    required List<String> topArtists,
    required Set<String> likedIds,
    required Map<String, Map<String, dynamic>> stats,
    required Map<String, double> sourceScores,
  }) {
    if (seed != null) {
      final seedArtists = _tokens(seed.artist);
      if (seedArtists.isNotEmpty &&
          _tokens(c.artist).any(seedArtists.contains)) {
        return 'Because you played ${seed.title}';
      }
    }
    for (final s in session.skip(1)) {
      if (_tokens(s.artist).any(_tokens(c.artist).contains)) {
        return 'Similar to your recent music';
      }
    }
    if (likedIds.contains(c.id)) return 'A track you liked';
    final source = sourceScores[c.videoId ?? c.id] ?? sourceScores[c.id];
    if (source != null) return 'YouTube Music radio';
    if (_artistAffinity(c.artist, topArtists) > 0) {
      return 'Popular with listeners of ${c.artist}';
    }
    if ((stats[c.id]?['playCount'] as int? ?? 0) > 0) {
      return 'Back from your rotation';
    }
    return 'Picked for you';
  }

  static const Set<String> _genericTokens = {
    'the',
    'and',
    'feat',
    'ft',
    'official',
    'audio',
    'video',
    'song',
    'songs',
    'music',
    'lyrics',
    'lyric',
    'topic',
    'vevo',
    'records',
    'record',
    'label',
    'album',
    'deluxe',
    'remaster',
    'remastered',
    'version',
    'full',
    'hd',
    '4k',
  };

  static Set<String> _tokens(String s) => SongFilter.fold(s)
      .split(RegExp(r'[^a-z0-9\u00c0-\u024f\u0900-\u097f]+'))
      .where((t) => t.length > 1 && !_genericTokens.contains(t))
      .toSet();

  static String _normTitle(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _Scored {
  final Song song;
  final double score;
  _Scored(this.song, this.score);
}
