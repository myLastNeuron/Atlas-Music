import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../media/lyrics_model.dart';
import '../models/song.dart';

/// Synced lyrics via LRCLIB (https://lrclib.net, free, no key).
/// Fallback chain per song (memory → disk → network):
///   1. /api/get track+artist+duration     (exact, best precision)
///   2. /api/get track+artist               (exact, no duration)
///   3. /api/get track+duration             (artist drift on LRCLIB keys,
///      duration-verified so same-title wrong tracks are rejected)
///   4. /api/search?q=track artist          (fuzzy, title+artist guarded,
///      duration-verified title fallback)
/// Never throws: every failure resolves to null and the
/// sheet shows a "not found" state.
///
/// Wrong-lyrics guard: title-only matches (steps 3–4) are the classic
/// source of wrong text (same title, different song). A hit is accepted
/// only when its duration is within [_durationTolerance] of the song, or
/// its artist overlaps ours. No positive contradiction + no overlap is
/// still a miss — a miss beats wrong lyrics.
///
/// NOTE: LRCLIB /api/search ONLY accepts a single `q` param —
/// `track_name`/`artist_name` are for /api/get only.
///
/// NOTE 2: YouTube titles come as "Artist - Title" as often as
/// "Title (Official Video)". [cleanTrack] keeps the FIRST segment, and
/// [trackVariants] also tries the LAST, so both shapes resolve.
class LyricsService {
  static const _host = 'lrclib.net';
  static const _roundTimeout = Duration(seconds: 12);
  static const _netBudget = Duration(seconds: 30);
  /// Max |LRCLIB duration − song duration| for a title-only hit to count
  /// as our song. Loose on purpose: music videos often carry short
  /// intros/outros the audio entry lacks. Same-title wrong tracks
  /// usually differ by far more.
  static const _durationToleranceSec = 10;
  static const _diskTtl = Duration(days: 30);
  static const _ua =
      'AtlasMusic/2.0.1 (https://github.com/myLastNeuron/Atlas-Music)';

  final http.Client _http;
  // Persistent app folder, not systemTemp: downloaded lyrics must survive
  // the OS clearing temp files, or they are gone when the device is offline.
  final Future<Directory> _dir;
  final Map<String, SyncedLyrics?> _mem = {};

  LyricsService({http.Client? client, Directory? dir})
      : _http = client ?? http.Client(),
        _owned = client == null,
        _dir = dir != null
            ? Future.value(dir)
            : getApplicationDocumentsDirectory();

  final bool _owned;

  /// Closes the owned HTTP client. Safe to call on an injected client
  /// (no-op): the caller owns that one.
  void dispose() {
    if (_owned) _http.close();
  }

  /// Fetches and keeps lyrics for a downloaded song. Pinned on disk, so the
  /// 30-day TTL never removes them and the sheet works offline.
  static Future<void> saveForDownload(Song song) async {
    final lyrics = LyricsService();
    try {
      final found = await lyrics.fetch(song);
      if (found != null) {
        await lyrics._writeDisk(lyrics._cacheKey(song), found, pinned: true);
      }
    } finally {
      lyrics.dispose();
    }
  }

  /// Lines per translation request: small enough that a merge or a split stays
  /// inside one batch, big enough to keep a whole song to a handful of calls.
  static const _translateBatch = 12;

  /// Translates lyric lines into [target] (language code) with Google's free
  /// endpoint. Returns null when offline or when nothing could be translated.
  ///
  /// Line alignment is the whole problem here. Google drops blank lines and
  /// merges or splits sentences, so one request for the whole song came back
  /// with a different number of lines and the caller threw it away — which is
  /// what made Devanagari lyrics read as "untranslatable". Blank lines are now
  /// mapped separately, the rest go in small batches in parallel, and a batch
  /// that still comes back reshaped is retried one line at a time, where a
  /// mismatch is impossible.
  ///
  /// Romanised Hindi needed a second fix: auto-detect calls "tum hi ho" English
  /// and returns it untouched. Text that looks romanised is sent as Hindi.
  // ponytail: unofficial endpoint, may break; swap for ML Kit or a paid API if it does.
  Future<List<String>?> translate(List<String> lines, String target) async {
    final indexes = [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].trim().isNotEmpty) i
    ];
    if (indexes.isEmpty) return null;

    final batches = <List<int>>[];
    for (var start = 0; start < indexes.length; start += _translateBatch) {
      final end = start + _translateBatch;
      batches.add(indexes.sublist(
          start, end > indexes.length ? indexes.length : end));
    }
    final results = await Future.wait([
      for (final batch in batches)
        _translateBlockOf([for (final i in batch) lines[i]], target),
    ]);
    if (results.any((r) => r == null)) return null;

    final out = List<String>.filled(lines.length, '');
    for (var b = 0; b < batches.length; b++) {
      final translated = results[b]!;
      for (var k = 0; k < batches[b].length; k++) {
        out[batches[b][k]] = translated[k];
      }
    }
    return out;
  }

  /// One batch: a single newline-joined request, else one request per line.
  Future<List<String>?> _translateBlockOf(
      List<String> lines, String target) async {
    final block = await _translateText(lines.join('\n'), target);
    if (block != null) {
      final parts = block.split('\n');
      if (parts.length == lines.length) return parts;
    }
    // Reshaped: a request per line cannot misalign.
    final out = <String>[];
    for (final line in lines) {
      final one = await _translateText(line, target);
      if (one == null) return null;
      out.add(_collapse(one));
    }
    return out;
  }

  /// Sends one block of text, choosing the source language.
  Future<String?> _translateText(String text, String target) async {
    if (text.trim().isEmpty) return null;
    final romanHindi = looksRomanHindi(text);
    // Hindi first for romanised lyrics: with `auto` the text is detected as
    // English and handed straight back, which is the bug being fixed.
    for (final source in romanHindi ? const ['hi', 'auto'] : const ['auto']) {
      final result = await _translateOnce(text, target, source);
      if (result == null) continue;
      if (romanHindi && _sameText(result, text)) continue;
      return result;
    }
    return null;
  }

  Future<String?> _translateOnce(
      String text, String target, String source) async {
    try {
      final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
        'client': 'gtx',
        'sl': source,
        'tl': target,
        'dt': 't',
      });
      final resp = await _http
          .post(uri, headers: {'User-Agent': _ua}, body: {'q': text})
          .timeout(_netBudget);
      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body) as List;
      if (data.isEmpty || data[0] is! List) return null;
      return (data[0] as List)
          .map((seg) =>
              seg is List && seg.isNotEmpty ? (seg[0] as String? ?? '') : '')
          .join();
    } catch (_) {
      return null;
    }
  }

  static bool _sameText(String a, String b) =>
      _collapse(a).toLowerCase() == _collapse(b).toLowerCase();

  /// Romanised Hindi ("tum hi ho", "dil hai") — Latin script, Hindi words.
  /// The markers are Hindi-only spellings (no English word looks like them),
  /// so a single hit is enough; short lyric lines often carry just one.
  // shortcut: word-list heuristic. Swap for a language-ID model if it misfires
  // on English lyrics or misses heavily code-mixed ones.
  static final RegExp _romanHindiWords = RegExp(
      r'\b(hai|hain|nahi|nahin|kya|kyun|kyu|tum|tumhe|tera|teri|tere|mera|'
      r'meri|mere|mujhe|tujhe|humko|tumko|dil|pyaar|pyar|ishq|jaan|jaana|'
      r'jaaniye|zindagi|sapna|sapne|yaar|khuda|duniya|baat|baatein|raat|'
      r'raatein|lamhe|aankhein|ankhon|nazar|sach|jhooth|kabhi|phir|abhi|'
      r'bahut|bohot|kuch|sab|sath|saath|zara|bata|kaise|kaisa|chale|chalta|'
      r'raha|rahi|rahe|gaya|gayi|hoga|hogi)\b',
      caseSensitive: false);

  /// True when [text] is Latin-script romanised Hindi. Devanagari returns
  /// false: auto-detect already knows it, and forcing Hindi changes nothing.
  static bool looksRomanHindi(String text) {
    if (RegExp(r'[\u0900-\u097F]').hasMatch(text)) return false;
    return _romanHindiWords.hasMatch(text.toLowerCase());
  }

  /// Strips YouTube junk so "Blinding Lights (Official Video)"
  /// queries as "Blinding Lights". Public + static for tests.
  static String cleanTrack(String raw, {bool keepSeparator = false}) {
    var s = raw;
    s = s.replaceAll(RegExp(r'\.{3,}'), '');
    s = s.replaceAll(RegExp(r'\.{2,}'), '');
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    s = s.replaceAll(RegExp(r'\([^)]*(official|video|audio|lyric|visualizer|remix|cover|live|mv|m\/v)[^)]*\)', caseSensitive: false), ' ');
    // Drop "(From ...)" / "(Feat ...)" suffixes, keep core title.
    s = s.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    if (!keepSeparator) {
      for (final sep in [' - ', ' | ', ' ~ ', ' // ']) {
        if (s.contains(sep)) {
          s = s.split(sep).first;
        }
      }
    }
    s = s.replaceAll(RegExp(r'\s+(feat\.?|ft\.?)\s+.*$', caseSensitive: false), ' ');
    return _collapse(s);
  }

  /// Keeps the first artist: "A, B & C feat D" → "A".
  /// Drops YouTube's " - Topic" suffix. Public + static for tests.
  static String cleanArtist(String raw) {
    var s = raw.replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), ' ');
    for (final sep in [',', '&', ' x ', ' X ', ' feat', ' FEAT', ' ft', ' FT']) {
      if (s.contains(sep)) {
        s = s.split(sep).first;
      }
    }
    return _collapse(s);
  }

  static String _collapse(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Ordered title candidates for one raw song title.
  /// [cleanTrack] alone keeps the FIRST " - "-separated segment, which is
  /// the artist half of YouTube's "Artist - Title" format. The last
  /// segment is usually the real title there ("Pritam - Kesariya" →
  /// "Kesariya"), while first-wins cases ("Kesariya - Live") still hit
  /// on candidate one. Junk last segments ("Live", "Remix") are dropped.
  /// Public + static for tests.
  static List<String> trackVariants(String raw) {
    final out = <String>[];
    void add(String v) {
      v = _collapse(v);
      if (v.length > 1 && !out.contains(v)) out.add(v);
    }

    add(cleanTrack(raw));
    add(_lastSegment(raw));
    add(cleanSoft(raw));
    return out;
  }

  static String _lastSegment(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    s = s.replaceAll(
        RegExp(
            r'\([^)]*(official|video|audio|lyric|visualizer|remix|cover|live|mv|m\/v)[^)]*\)',
            caseSensitive: false),
        ' ');
    var parts = <String>[s];
    for (final sep in [' - ', ' | ', ' ~ ', ' // ', ' : ', ':', '—', '–']) {
      final next = <String>[];
      for (final p in parts) {
        next.addAll(p.split(sep));
      }
      parts = next;
    }
    final cands =
        parts.map(_collapse).where((p) => p.isNotEmpty).toList();
    if (cands.length < 2) return '';
    var last = cands.last.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    last = _collapse(last);
    if (last.length < 2 || _junkSegment.contains(last.toLowerCase())) {
      return '';
    }
    return last;
  }

  /// Last-segment values that are section labels, not titles.
  static const _junkSegment = {
    'live',
    'lyrics',
    'lyric',
    'audio',
    'video',
    'official',
    'mv',
    'm/v',
    'cover',
    'remix',
    'acoustic',
    'instrumental',
    'karaoke',
    'visualizer',
    'version',
    'full',
    'song',
    'music',
    'slowed',
    'reverb',
    'sped up',
    'speed up',
    'tiktok',
    'shorts',
    'hd',
    'hq',
    '4k',
    '8d',
    '1 hour',
    '10 hours',
    'loop',
    'looped',
    'extended',
  };

  /// True when two titles share a real word. Guards fuzzy search picks:
  /// a result titled nothing like the query is never our song, even if
  /// the artist overlaps (compilations, same-artist wrong track).
  static bool _trackOverlaps(String a, String b) {
    final ta = _wordTokens(a);
    final tb = _wordTokens(b);
    for (final t in ta) {
      if (tb.contains(t)) return true;
    }
    return false;
  }

  static Set<String> _wordTokens(String s) {
    return s
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9\u00c0-\u024f\u1e00-\u1eff\u0900-\u097f]+'))
        .where((t) => t.length > 1)
        .toSet();
  }
  /// keep everything else intact (title parentheticals, artist combos).
  /// Gentle clean: strip only trailing "(Official Video)" style junk,
  /// keep everything else intact (title parentheticals, artist combos).
  static String cleanSoft(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'\.{3,}'), '');
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    s = s.replaceAll(RegExp(r'\([^)]*(official|video|audio|subject|ytc[^)]*|visualizer)[^)]*\)', caseSensitive: false), ' ');
    return _collapse(s);
  }

  /// True when LRCLIB's artist string shares at least one token with the
  /// song's artist → guards a title-only /api/get against a wrong song
  /// and ranks search hits. Token-splits on , & x / feat.
  static bool _artistOverlaps(String a, String b) {
    final ta = _artistTokens(a);
    final tb = _artistTokens(b);
    for (final t in ta) {
      if (tb.contains(t)) return true;
    }
    return false;
  }

  static Set<String> _artistTokens(String s) {
    var v = s.toLowerCase()
        .replaceAll(RegExp(r'\bfeat\.?\b|\bft\.?\b|\band\b|\bx\b'), ' ');
    for (final sep in [',', '&', ';', '/', '|']) {
      v = v.replaceAll(sep, ' ');
    }
    return v.split(RegExp(r'\s+'))
        .where((t) => t.length > 1)
        .toSet();
  }

  static String safeKey(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  String _cacheKey(Song song) {
    // The whole title, not the search-side cleanTrack (which keeps only the
    // first "Artist - Title" segment): two songs by one artist would share a
    // key and be served each other's lyrics.
    final t = cleanTrack(song.title, keepSeparator: true).toLowerCase();
    final a = cleanArtist(song.artist).toLowerCase();
    return 'lyrics_${safeKey(a)}__${safeKey(t)}';
  }

  Future<SyncedLyrics?> fetch(Song song) async {
    final key = _cacheKey(song);
    if (_mem.containsKey(key)) return _mem[key];

    final disk = await _readDisk(key);
    if (disk != null) {
      _mem[key] = disk;
      return disk;
    }

    final tracks = trackVariants(song.title);
    final artist = cleanArtist(song.artist);
    final artists = <String>[
      if (artist.isNotEmpty) artist,
      if (cleanSoft(song.artist).isNotEmpty &&
          cleanSoft(song.artist) != artist)
        cleanSoft(song.artist),
    ];
    if (tracks.isEmpty) {
      _mem[key] = null;
      return null;
    }

    // Whole network phase shares one budget: true misses must resolve
    // to "not found" in seconds, not after every round times out.
    SyncedLyrics? found;
    var networkReached = true;
    try {
      found = await _fetchNetwork(song, tracks, artists)
          .timeout(_netBudget, onTimeout: () {
        networkReached = false;
        return null;
      });
    } catch (_) {
      networkReached = false;
      found = null;
    }

    // Cache a genuine miss (LRCLIB answered "nothing") so repeat opens are
    // instant, but only for this session — no disk write for a miss. Do NOT
    // cache a network failure/timeout: the device may be offline now and
    // online a moment later, and a memoized failure would keep the sheet
    // stuck on "not found" until the app restarts.
    if (networkReached) _mem[key] = found;
    if (found != null) await _writeDisk(key, found);
    return found;
  }

  Future<SyncedLyrics?> _fetchNetwork(
    Song song,
    List<String> tracks,
    List<String> artists,
  ) async {
    final primary = artists.isNotEmpty ? artists.first : '';
    SyncedLyrics? found;
    // 1. Exact get with duration (best precision).
    if (song.duration.inSeconds > 0) {
      for (final t in tracks) {
        found = await _get(
          track: t,
          artist: primary,
          duration: song.duration.inSeconds,
          labelTrack: song.title,
          labelArtist: song.artist,
        );
        if (found != null) return found;
      }
    }
    // 2. Exact get without duration, primary then secondary artist.
    for (final a in artists) {
      for (final t in tracks) {
        found = await _get(
          track: t,
          artist: a,
          labelTrack: song.title,
          labelArtist: song.artist,
        );
        if (found != null) return found;
      }
    }
    // 3. Title + duration (artist on LRCLIB may be composer, not
    // singer). Duration goes along so the server disambiguates, and
    // _get additionally rejects duration contradictions.
    final withDuration = song.duration.inSeconds > 0
        ? song.duration.inSeconds
        : null;
    for (final t in tracks) {
      found = await _get(
        track: t,
        artist: null,
        duration: withDuration,
        labelTrack: song.title,
        labelArtist: song.artist,
      );
      if (found != null) return found;
    }
    // 4. Fuzzy search, title-guarded so same-artist wrong tracks lose.
    final queries = <_Query>[];
    void addQuery(String q, String track) {
      if (q.trim().length > 1 &&
          !queries.any((e) => e.q == q)) {
        queries.add(_Query(q, track));
      }
    }

    for (final t in tracks) {
      for (final a in artists) {
        addQuery('$t $a', t);
      }
    }
    for (final t in tracks) {
      addQuery(t, t);
    }
    final rawTrack = cleanSoft(song.title);
    final rawArtist = cleanSoft(song.artist);
    if (rawTrack.isNotEmpty && rawArtist.isNotEmpty) {
      addQuery('$rawTrack $rawArtist', rawTrack);
    }
    for (final q in queries.take(5)) {
      found = await _searchOnce(
        q.q,
        queryTrack: q.track,
        labelArtist: song.artist,
        labelDuration: song.duration.inSeconds,
      );
      if (found != null) return found;
    }
    return null;
  }

  Future<SyncedLyrics?> _get({
    required String track,
    String? artist,
    int? duration,
    required String labelTrack,
    required String labelArtist,
  }) async {
    try {
      final params = <String, String>{
        'track_name': track,
      };
      if (artist != null && artist.isNotEmpty) {
        params['artist_name'] = artist;
      }
      if (duration != null) params['duration'] = '$duration';
      final uri = Uri.https(_host, '/api/get', params);
      final resp = await _http
          .get(uri, headers: {'User-Agent': _ua, 'Accept': 'application/json'})
          .timeout(_roundTimeout);
      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body);
      if (data is! Map<String, dynamic>) return null;
      // Ignore a hit that clearly belongs to a different song.
      final srcArtist = (data['artistName'] as String?)?.trim() ?? '';
      if (artist != null && artist.isNotEmpty) {
        if (srcArtist.isNotEmpty &&
            !_artistOverlaps(artist, srcArtist)) {
          return null;
        }
      } else {
        // Title-only hit: no artist to check, so the duration must not
        // contradict (same title, different song). Missing duration info
        // on either side is not a contradiction — accept and let the
        // artist-overlap bonus below decide nothing.
        final srcDur = (data['duration'] as num?)?.toDouble();
        if (duration != null &&
            duration > 0 &&
            srcDur != null &&
            (srcDur - duration).abs() > _durationToleranceSec) {
          return null;
        }
      }
      return _fromJson(data, fallbackTrack: labelTrack, fallbackArtist: labelArtist);
    } catch (_) {
      return null;
    }
  }

  Future<SyncedLyrics?> _searchOnce(
    String q, {
    required String queryTrack,
    required String labelArtist,
    required int labelDuration,
  }) async {
    try {
      // LRCLIB /api/search takes a single 'q' param only.
      final uri = Uri.https(_host, '/api/search', {'q': q});
      final resp = await _http
          .get(uri, headers: {'User-Agent': _ua, 'Accept': 'application/json'})
          .timeout(_roundTimeout);
      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body);
      if (data is! List || data.isEmpty) return null;
      final items = data.whereType<Map<String, dynamic>>().toList();
      if (items.isEmpty) return null;
      // Title must overlap the query track AND artist must overlap
      // (or artist unknown). First synced dual-match wins. No blind
      // items.first fallback: it returned unrelated songs.
      // Title-only fallback additionally requires no duration
      // contradiction, so same-title wrong tracks lose.
      Map<String, dynamic>? overlapPick;
      Map<String, dynamic>? titlePick;
      for (final it in items) {
        final synced = (it['syncedLyrics'] as String?) ?? '';
        if (synced.trim().isEmpty) continue;
        final srcTrack = (it['trackName'] as String?)?.trim() ?? '';
        if (!_trackOverlaps(queryTrack, srcTrack)) continue;
        final srcDur = (it['duration'] as num?)?.toDouble();
        final durClash = labelDuration > 0 &&
            srcDur != null &&
            (srcDur - labelDuration).abs() > _durationToleranceSec;
        if (!durClash) titlePick ??= it;
        final srcArtist = (it['artistName'] as String?)?.trim() ?? '';
        if (labelArtist.trim().isEmpty ||
            _artistOverlaps(labelArtist, srcArtist)) {
          overlapPick = it;
          break;
        }
      }
      final pick = overlapPick ?? titlePick;
      if (pick == null) return null;
      return _fromJson(pick,
          fallbackTrack: queryTrack, fallbackArtist: labelArtist);
    } catch (_) {
      return null;
    }
  }

  SyncedLyrics? _fromJson(    Map<String, dynamic> data, {
    required String fallbackTrack,
    required String fallbackArtist,
  }) {
    final instrumental = data['instrumental'] == true;
    final track = (data['trackName'] as String?)?.trim();
    final artist = (data['artistName'] as String?)?.trim();
    final synced = (data['syncedLyrics'] as String?) ?? '';
    final plain = (data['plainLyrics'] as String?) ?? '';
    if (instrumental) {
      return SyncedLyrics(
        track: (track?.isNotEmpty ?? false) ? track! : fallbackTrack,
        artist: (artist?.isNotEmpty ?? false) ? artist! : fallbackArtist,
        lines: const [],
        isSynced: false,
        instrumental: true,
      );
    }
    final lines = synced.trim().isEmpty ? <LyricLine>[] : parseLrc(synced);
    if (lines.isNotEmpty) {
      return SyncedLyrics(
        track: (track?.isNotEmpty ?? false) ? track! : fallbackTrack,
        artist: (artist?.isNotEmpty ?? false) ? artist! : fallbackArtist,
        lines: lines,
        isSynced: true,
      );
    }
    if (plain.trim().isNotEmpty) {
      return SyncedLyrics(
        track: (track?.isNotEmpty ?? false) ? track! : fallbackTrack,
        artist: (artist?.isNotEmpty ?? false) ? artist! : fallbackArtist,
        lines: const [],
        isSynced: false,
        plain: plain.trim(),
      );
    }
    return null;
  }

  Future<SyncedLyrics?> _readDisk(String key) async {
    try {
      final f = File('${(await _dir).path}/$key.json');
      if (!await f.exists()) return null;
      final raw = json.decode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      final at = DateTime.tryParse(raw['fetchedAt'] as String? ?? '');
      if (raw['pinned'] != true &&
          (at == null || DateTime.now().difference(at) > _diskTtl)) {
        try {
          await f.delete();
        } catch (_) {}
        return null;
      }
      if (raw['instrumental'] == true) {
        return SyncedLyrics(
          track: (raw['track'] as String?) ?? '',
          artist: (raw['artist'] as String?) ?? '',
          lines: const [],
          isSynced: false,
          instrumental: true,
        );
      }
      final isSynced = raw['isSynced'] == true;
      if (isSynced) {
        final list = (raw['lines'] as List?) ?? [];
        final lines = <LyricLine>[];
        for (final e in list) {
          if (e is! List || e.length < 2) continue;
          final ms = e[0] is int ? e[0] as int : int.tryParse('${e[0]}') ?? 0;
          lines.add(LyricLine(
            start: Duration(milliseconds: ms),
            text: '${e[1]}',
          ));
        }
        if (lines.isEmpty) return null;
        return SyncedLyrics(
          track: (raw['track'] as String?) ?? '',
          artist: (raw['artist'] as String?) ?? '',
          lines: lines,
          isSynced: true,
        );
      }
      final plain = (raw['plain'] as String?) ?? '';
      if (plain.trim().isEmpty) return null;
      return SyncedLyrics(
        track: (raw['track'] as String?) ?? '',
        artist: (raw['artist'] as String?) ?? '',
        lines: const [],
        isSynced: false,
        plain: plain,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String key, SyncedLyrics lyrics,
      {bool pinned = false}) async {
    try {
      final f = File('${(await _dir).path}/$key.json');
      await f.writeAsString(json.encode({
        'track': lyrics.track,
        'artist': lyrics.artist,
        'pinned': pinned,
        'isSynced': lyrics.isSynced,
        'instrumental': lyrics.instrumental,
        'plain': lyrics.plain ?? '',
        'lines': lyrics.lines
            .map((l) => [l.start.inMilliseconds, l.text])
            .toList(),
        'fetchedAt': DateTime.now().toIso8601String(),
      }));
    } catch (_) {}
  }
}

/// Search query paired with the title variant it came from, so picks
/// can require title overlap with the query (not just artist).
class _Query {
  final String q;
  final String track;
  _Query(this.q, this.track);
}
