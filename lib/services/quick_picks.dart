import '../models/song.dart';
import 'song_filter.dart';
import 'user_prefs.dart';

/// Personalized Quick Picks ranking — pure logic, no plugins, unit-tested.
///
/// The signal is deliberately small and honest. What the engine can actually
/// see on this device (no audio-feature API, no backend): YouTube
/// titles/artists/channels, listening stats (last-played, so recently played
/// tracks are excluded), the recent session, likes, and the user's top/selected
/// artists. Picks are ranked by session-artist overlap, liked tracks, and
/// top/selected artists, then filtered and de-duplicated by the global
/// [SongFilter] rules. Rankings state this openly instead of pretending to
/// model taste from audio features that do not exist here.
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

  /// Rank [candidates] for the session led by [recent] (most-recent-first,
  /// [recent.first] is the seed). Returns at most [count] picks, strongest
  /// first, capped at [maxPerArtist] per artist. Never throws.
  static List<QuickPick> rank({
    required List<Song> recent,
    required List<Song> candidates,
    Map<String, Map<String, dynamic>> stats = const {},
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
        final inTop = _artistInList(c.artist, topArtists);
        final inSelected = _artistInList(c.artist, selectedArtists);
        if (requirePersonalSignal &&
            !(artistOverlap || liked || inTop || inSelected)) {
          continue;
        }

        var score = 0.0;
        if (artistOverlap) score += 0.6;
        if (liked) score += 0.25;
        if (inTop) score += 0.1;
        if (inSelected) score += 0.1;
        scored.add(_Scored(c, score.clamp(0.0, 1.0)));
      }

      scored.sort((a, b) => b.score.compareTo(a.score));
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
                ),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
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
    if (_artistInList(c.artist, topArtists)) {
      return 'Popular with listeners of ${c.artist}';
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
