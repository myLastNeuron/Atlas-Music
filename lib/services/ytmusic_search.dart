import 'dart:convert';

import 'package:http/http.dart' as http;

import '../media/resolve_failure.dart';
import '../models/artist.dart';
import '../models/song.dart';

/// A video row: the id to play plus YouTube's classification, so a caller can
/// tell an official music video (MUSIC_VIDEO_TYPE_OMV) from an upload
/// (MUSIC_VIDEO_TYPE_UGC) or an art track (_ATV). [channel] is the uploader
/// on plain YouTube and the credited artist on catalogue rows; the policy
/// only needs one identity it can test for "label" and "artist".
class VideoCandidate {
  final String videoId;
  final String musicVideoType;
  final String title;
  final String channel;

  const VideoCandidate({
    required this.videoId,
    required this.musicVideoType,
    required this.title,
    required this.channel,
  });

  /// A plain youtube.com row, which carries no YouTube classification.
  factory VideoCandidate.fromSong(Song song) => VideoCandidate(
        videoId: song.videoId ?? song.id,
        musicVideoType: '',
        title: song.title,
        channel: song.channel.isEmpty ? song.artist : song.channel,
      );

  /// YouTube's own "official music video" classification.
  bool get official => musicVideoType == 'MUSIC_VIDEO_TYPE_OMV';
}

/// Searches the YouTube Music catalogue directly (InnerTube `WEB_REMIX`
/// client) instead of plain youtube.com search.
///
/// Why: plain YouTube search has no song/video distinction, so a query like
/// "wonderwall" returns lyric re-uploads, covers and music videos from random
/// channels mixed in with the actual song. YouTube Music classifies its
/// catalogue, and the "Songs" filter returns only songs (official audio
/// tracks) — no music videos, lyric uploads or covers.
///
/// This client also drives the artist page: [resolveArtistId] turns an artist
/// *name* (all we have — [Song.artist] is a plain string) into a channel id,
/// then [browseArtist] reads the same `browse` endpoint the web player uses
/// for songs / albums / singles. Parsing is static so it is unit-testable
/// against fixtures without a network.
///
/// The request shape (client context, endpoint, filter params) mirrors what
/// sigma67's ytmusicapi sends. No auth is needed for public search/browse.
class YouTubeMusicSearch {
  YouTubeMusicSearch({http.Client? client}) : _client = client ?? http.Client();

  static const Duration _timeout = Duration(seconds: 20);
  static const int _maxPages = 30;

  /// Search pages followed per query. Each page is one request, so a
  /// bounded count keeps a slow connection from stalling the search.
  static const int _maxSearchPages = 4;
  static const String _searchUrl =
      'https://music.youtube.com/youtubei/v1/search';
  static const String _browseUrl =
      'https://music.youtube.com/youtubei/v1/browse';
  static const String _nextUrl = 'https://music.youtube.com/youtubei/v1/next';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) '
      'Gecko/20100101 Firefox/88.0';

  /// `get_search_params(filter="songs")` = "EgWKAQ" + "II" + "AWoMEA…".
  static const String _songsParams = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';

  /// `get_search_params(filter="videos")`. Verified live (2026-10): returns
  /// MUSIC_VIDEO_TYPE_OMV / _UGC / _PODCAST_EPISODE rows, while
  /// [_songsParams] returns only MUSIC_VIDEO_TYPE_ATV art tracks.
  static const String _videosParams = 'EgWKAQIQAWoMEA4QChADEAQQCRAF';

  final http.Client _client;

  /// Songs only (no music videos). Returns an empty list when the query has
  /// no song entries — callers may fall back to video results.
  Future<List<Song>> searchSongs(String query, {int limit = 20}) async {
    final songs = await _search(query, _songsParams, limit: limit);
    if (songs.isNotEmpty) return songs;
    // Not in the catalogue (regional / indie tracks exist only as videos).
    // The same query without the song filter still carries those rows in its
    // other tabs, so read them before falling back to plain YouTube.
    return _search(query, '', limit: limit);
  }

  /// Real music videos (and uploads) for [query] with YouTube's own
  /// classification, one page only: this feeds the Video toggle's fallback
  /// for songs whose catalogue entry is a still art track, and must answer
  /// fast. Ranked by [pickOfficialVideo].
  Future<List<VideoCandidate>> searchVideos(
    String query, {
    int limit = 20,
  }) async {
    final data = await _post(_searchUrl, {
      'query': query,
      'params': _videosParams,
    });
    final out = <VideoCandidate>[];
    final seen = <String>{};
    for (final item in _songItems(data)) {
      if (out.length >= limit) break;
      final song = _toSong(item);
      if (song == null) continue;
      final videoId = song.videoId ?? song.id;
      if (!seen.add(videoId)) continue;
      // A missing config block only means YouTube did not classify the row;
      // dropping it used to disable the whole fallback on such responses.
      final type = _videoType(item) ?? '';
      out.add(VideoCandidate(
        videoId: videoId,
        musicVideoType: type,
        title: song.title,
        channel: song.channel,
      ));
    }
    return out;
  }

  /// The official video for [title] by [artist] among [videos], or null.
  ///
  /// One policy for catalogue rows and plain youtube.com search alike:
  /// YouTube's OMV classification, a label channel, or the artist's own
  /// channel. Topic channels, art tracks, lyric/audio uploads, other songs
  /// and fan reuploads are rejected; a missing official video is null, never
  /// the nearest plausible upload. Accepted rows rank OMV, then label, then
  /// artist channel; the artist being named breaks a tie. The song's own id
  /// [excludeId] is skipped. Pure for the test.
  static VideoCandidate? pickOfficialVideo(
    List<VideoCandidate> videos, {
    required String title,
    required String artist,
    required String excludeId,
  }) {
    VideoCandidate? best;
    var bestScore = 0;
    for (final c in videos) {
      if (c.videoId == excludeId) continue;
      // Auto-generated Topic channels are not the artist's own upload, and
      // ATV/podcast rows are not the song's video at all.
      if (c.channel.trim().toLowerCase().endsWith(' - topic')) continue;
      final omv = c.official;
      final ugc = c.musicVideoType == 'MUSIC_VIDEO_TYPE_UGC';
      if (!omv && !ugc && c.musicVideoType.isNotEmpty) continue;
      // The row must be THIS song: a title that merely contains the wanted
      // one is a different track, and a slowed/remix upload is another
      // recording. Only YouTube's OMV classification vouches for a channel
      // that is neither the label nor the artist.
      if (!isSameSong(
        candidate: c.title,
        wantTitle: title,
        artist: artist,
        channel: c.channel,
        requireArtist: !omv,
        originalChannel: !omv,
        realVideo: true,
      )) {
        continue;
      }
      final label = _isLabelChannel(c.channel);
      final own = _namesArtist(c.channel, artist);
      final named = own || _namesArtist('${c.title} ${c.channel}', artist);
      // Separate bands keep OMV above every label upload and the label above
      // the artist's own channel; the classification and a named artist only
      // break ties inside a band.
      final score = (omv ? 100 : (label ? 50 : 10)) +
          (ugc ? 1 : 0) +
          (named ? 1 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best;
  }

  /// Songs whose title needs no other words to be the same song; anything a
  /// video title adds on top (release suffixes, channel noise) is ignored.
  static const Set<String> _titleNoise = {
    'official',
    'video',
    'music',
    'audio',
    'lyric',
    'lyrics',
    'visualizer',
    'mv',
    'm',
    'v',
    'hd',
    'hq',
    '4k',
    '8k',
    'remaster',
    'remastered',
    'explicit',
    'version',
    'from',
    'the',
    'a',
    'an',
    'feat',
    'ft',
    'with',
    'and',
    'x',
    'by',
    'prod',
    'of',
    'edit',
    'ost',
    'soundtrack',
    'topic',
    'vevo',
    'records',
    'latest',
    'new',
    'premiere',
    'exclusive',
    'out',
    'now',
    'movie',
    'film',
    'album',
    'full',
    'song',
    'nsfw',
    'uncensored',
    'clean',
    'stereo',
    'mono',
    'lyrical',
    'visualiser',
    'coverart',
  };

  /// Channels that release music themselves: release/movie context in the
  /// title is normal there, while a personal channel with extra words is
  /// another version of the song.
  static final RegExp _labelChannel = RegExp(
    r'(vevo|records|recordings|tseries|sony|universal|warner|'
    r'atlantic|interscope|republic|capitol|columbia|island|defjam|spinnin|'
    r'ultra|saregama|zeemusic|tips|speedrecords|adityamusic|believe|'
    r'yrf|yashraj)',
  );

  static bool _isLabelChannel(String channel) =>
      _labelChannel.hasMatch(channel.toLowerCase().replaceAll(
            RegExp(r'[^a-z0-9]'),
            '',
          ));

  /// Every "(...)"/"[...]" group of a video title.
  static final RegExp _brackets = RegExp(r'[\(\[]([^\)\]]*)[\)\]]');

  /// Uploads that are a *different recording* of the song: the video for a
  /// track must be that track, and a slowed/lo-fi/remix version is not it.
  static final RegExp _variant = RegExp(
    r'\b(slow|slowed|slower|reverb|nightcore|sped\s*up|speed\s*up|spedup|'
    r'lofi|lo-fi|remix|remixed|remixes|synthwave|night\s*mode|flip|medley|'
    r'mashup|mega\s*mix|karaoke|instrumental|cover|acoustic|unplugged|'
    r'piano|live|8d|bass\s*boost(?:ed)?|boosted|bootleg|remake|ringtone|'
    r'parody|chill|chillout|loop|tiktok|reels|female|male|\d+\s*hours?)\b',
    unicode: true,
  );

  /// The same words after the spaces are taken out, so "S L O W E D" and
  /// "R E V E R B" (a common style on these uploads) are still caught.
  static final RegExp _variantCompact = RegExp(
    r'(slowed|reverb|nightcore|lofi|remix|cover|bassboost|spedup|speedup|'
    r'karaoke|instrumental)',
  );

  /// Uploads that are not the song's video at all: a lyric card, a still
  /// cover, a translation. Only a real video counts when one is asked for.
  static const Set<String> _notVideo = {
    'lyric',
    'lyrics',
    'lyrical',
    'lirik',
    'letra',
    'letras',
    'visualizer',
    'visualiser',
    'audio',
    'subtitulado',
    'subtitles',
    'terjemahan',
  };

  /// Letters that stand in for Latin ones in these titles ("MC STΔN",
  /// "𝔼𝕂 𝔻𝕀ℕ"): folded before any comparison, or the artist is never
  /// recognised and a real video looks like a stranger's upload.
  static const Map<int, String> _lookalikes = {
    0x0394: 'a', // Δ GREEK CAPITAL DELTA
    0x2206: 'a', // ∆ INCREMENT
    0x03B4: 'd', // δ GREEK SMALL DELTA
  };

  /// [value] with lookalike letters folded to Latin.
  static String _fold(String value) {
    final out = StringBuffer();
    for (final rune in value.runes) {
      final mapped = _lookalikes[rune];
      if (mapped != null) {
        out.write(mapped);
        continue;
      }
      // Mathematical alphanumerics (U+1D400…) are 52-letter blocks, A–Z then
      // a–z; some styles have holes, which only costs a rejected match.
      if (rune >= 0x1D400 && rune <= 0x1D7FF) {
        final letter = (rune - 0x1D400) % 52;
        out.writeCharCode(0x61 + (letter < 26 ? letter : letter - 26));
        continue;
      }
      out.writeCharCode(rune);
    }
    return out.toString();
  }

  /// True when [artist] is named in [text]. Credit strings disagree on
  /// separators and spelling ("Vishal and Sheykhar" vs "Vishal - Shekhar"),
  /// so the whole string rarely matches; one full artist name is enough.
  static bool _namesArtist(String text, String artist) {
    final have = _matchKey(text);
    final key = _matchKey(artist);
    if (key.isEmpty) return false;
    if (have.contains(key)) return true;
    for (final name in artist.split(
        RegExp(r'[,&/;]|\band\b|\bwith\b|\bfeat\b|\bft\b', unicode: true))) {
      final k = _matchKey(name);
      if (k.length >= 4 && have.contains(k)) return true;
    }
    return false;
  }

  /// True when [candidate] is [wantTitle] by [artist] (or [channel]): the
  /// wanted words appear in it as a run, and every other word is release
  /// noise, part of the artist name, or a featured artist. A title that only
  /// *contains* the wanted one is a different song. Pure for the test.
  static bool isSameSong({
    required String candidate,
    required String wantTitle,
    required String artist,
    String channel = '',
    bool requireArtist = false,
    bool originalChannel = false,
    bool realVideo = false,
  }) {
    final want = _words(_baseTitle(wantTitle));
    if (want.isEmpty) return false;
    final have = _words(candidate);
    final at = _runIndex(have, want);
    if (at < 0) return false;
    final rest = [...have.sublist(0, at), ...have.sublist(at + want.length)];
    // Words of the song's own title (brackets included) are never leftovers:
    // a release suffix the song itself carries cannot make its video a remix.
    final ownWords = _words(wantTitle).toSet();
    rest.removeWhere(ownWords.contains);
    // Only the song's artist, not the uploader's channel: a fan channel named
    // after its own version must not launder that version into the song.
    final artistWords = _words(artist);
    // Only the words OUTSIDE the wanted title decide the variant: a slowed
    // upload is rejected, a song actually called "Cover Me" is not.
    if (_variant.hasMatch('${rest.join(' ')} $channel')) return false;
    // A lyric or audio upload is the song, but not its video: asked for a
    // video, it is as good as none.
    if (realVideo && rest.any(_notVideo.contains)) return false;
    if (_variantCompact.hasMatch(rest.join(''))) return false;
    final label = _isLabelChannel(channel);
    // The label's upload and the artist's own channel speak for the song:
    // extra words there are release context (album, year, "Long Version"),
    // not another recording. A fan channel has to earn the title instead.
    final ownChannel = label || _namesArtist(channel, artist);
    // A bracketed segment names a version unless it is release noise:
    // "Kesariya (Synthwave)" is a remix, "Blinding Lights (Official Video)"
    // is not, and "Ek Din Pyaar (Tadipaar)" is the song's own album.
    if (!ownChannel) {
      for (final m in _brackets.allMatches(candidate)) {
        final words = _words(m.group(1) ?? '');
        if (words.every((w) =>
            _titleNoise.contains(w) ||
            ownWords.contains(w) ||
            artistWords.contains(w))) {
          continue;
        }
        return false;
      }
    }
    // Everything after a featured artist is that artist, not the title.
    final content = <String>[];
    for (final w in rest) {
      if (w == 'feat' || w == 'ft') break;
      if (artistWords.contains(w) || _titleNoise.contains(w)) continue;
      content.add(w);
    }
    final named = _namesArtist('$candidate $channel', artist);
    // The video of a song is the song's own: the label's upload or the
    // artist's channel. A fan reupload that merely names the artist (a slowed
    // or reverb version with a clean title) is some other recording.
    if (originalChannel && !ownChannel) return false;
    // A found video must show whose song it is: its own artist, or a label
    // channel. Anything else is some upload that happens to share the title
    // (seen: "Often" by a fan was a slowed remix, "Ethan Swope Version").
    if (requireArtist && !named && !label) return false;
    // Extra words are release/movie context on a label channel or the artist's
    // own; on a personal channel they name another version.
    if (!ownChannel) return content.isEmpty;
    return true;
  }

  /// Lowercased words of [value]: unicode letters/digits, in order.
  static List<String> _words(String value) => _fold(value)
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty)
      .toList();

  /// Index where [want] appears in [have] as consecutive words, or -1.
  static int _runIndex(List<String> have, List<String> want) {
    for (var i = 0; i + want.length <= have.length; i++) {
      var hit = true;
      for (var j = 0; j < want.length; j++) {
        if (have[i + j] != want[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return i;
    }
    return -1;
  }

  /// Song title without its "(From "…")"/"[Remastered]" suffixes: catalogue
  /// rows write the release name there, real video titles do not. A title that
  /// is entirely bracketed keeps its original form instead of becoming empty.
  static String _baseTitle(String title) {
    final stripped =
        title.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ').trim();
    return stripped.isEmpty ? title.trim() : stripped;
  }

  Future<List<Song>> _search(
    String query,
    String params, {
    required int limit,
  }) async {
    final body = <String, dynamic>{'query': query};
    if (params.isNotEmpty) body['params'] = params;
    final data = await _post(_searchUrl, body);
    final songs = <Song>[];
    final seen = <String>{};
    void add(Iterable<Map> items) {
      for (final item in items) {
        if (songs.length >= limit) return;
        final song = _toSong(item);
        if (song == null) continue;
        if (seen.add(song.videoId ?? song.id)) songs.add(song);
      }
    }

    add(_songItems(data));
    // YouTube Music paginates the list with a continuation token and the
    // first page holds only ~20-30 songs. Without following it the result
    // list stops there and long queries look truncated.
    var token = _continuationOf(data);
    for (var page = 0;
        token != null && page < _maxSearchPages && songs.length < limit;
        page++) {
      final Map<String, dynamic> next;
      try {
        next = await _post(_searchUrl, {'continuation': token});
      } catch (_) {
        // Keep the songs already collected instead of losing the whole list.
        break;
      }
      add(_songItems(next));
      token = _continuationOf(next);
    }
    return songs;
  }

  /// Resolves an artist *name* to its YouTube Music channel id (browseId).
  /// Tries the Songs catalogue first, then an unfiltered search. Returns null
  /// when no result carries an artist browse endpoint (unknown artist, or a
  /// composite "A, B" string that matches nothing).
  Future<String?> resolveArtistId(String name) async {
    if (_normalize(name).isEmpty) return null;
    for (final params in const [_songsParams, '']) {
      try {
        final body = <String, dynamic>{'query': name};
        if (params.isNotEmpty) body['params'] = params;
        final data = await _post(_searchUrl, body);
        final id = artistIdFromJson(data, name);
        if (id != null) return id;
      } catch (_) {
        // Try the next search shape; caller falls back to a plain list.
      }
    }
    return null;
  }

  /// Reads an artist page: header name/image, top songs, and albums/singles.
  Future<ArtistPage> browseArtist(String channelId) async {
    final data = await _post(_browseUrl, {'browseId': channelId});
    return parseArtistJson(data);
  }

  /// Reads a track list: one release (album / single / EP), or an artist's
  /// full "Songs" list. Follows continuation pages so long lists are not cut
  /// off after the first page.
  Future<List<Song>> browseAlbum(String albumBrowseId) async {
    final data = await _post(_browseUrl, {'browseId': albumBrowseId});
    final out = parseAlbumJson(data);
    final seen = {for (final s in out) s.videoId ?? s.id};
    var token = _continuationOf(data);
    for (var page = 0; token != null && page < _maxPages; page++) {
      final Map<String, dynamic> next;
      try {
        next = await _post(_browseUrl, const {},
            query: {'ctoken': token, 'continuation': token});
      } catch (_) {
        // Keep the songs already collected instead of losing the whole list.
        break;
      }
      for (final song in _shelfSongs(next)) {
        if (seen.add(song.videoId ?? song.id)) out.add(song);
      }
      token = _continuationOf(next);
    }
    return out;
  }

  /// The queue YouTube Music itself would play after [videoId]: its radio,
  /// seeded by the track. Order is YouTube's own ranking (closest match
  /// first), so callers can use the position as a similarity score.
  ///
  /// No account is used, so this carries YouTube's editorial/co-listen
  /// similarity, not the user's history — Atlas adds that on-device.
  Future<List<Song>> radio(String videoId, {int limit = 30}) async {
    final data = await _post(
      _nextUrl,
      {
        'videoId': videoId,
        // YouTube Music's song-radio playlist id. Without it the `next`
        // call returns only the seed track instead of the 50-track queue.
        'playlistId': 'RDAMVM$videoId',
        'isAudioOnly': true,
      },
    );
    return parseRadioJson(data, limit: limit);
  }

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body, {
    Map<String, String>? query,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _postOnce(url, body, query: query);
      } catch (e) {
        lastError = e;
        // Throttling is temporary: wait it out and ask again. Any other
        // failure (offline, bad payload) is final.
        if (!isRateLimited(e)) rethrow;
        await Future.delayed(Duration(milliseconds: 700 * (attempt + 1)));
      }
    }
    throw lastError!;
  }

  Future<Map<String, dynamic>> _postOnce(
    String url,
    Map<String, dynamic> body, {
    Map<String, String>? query,
  }) async {
    final resp = await _client
        .post(
          Uri.parse(url).replace(queryParameters: {
            'alt': 'json',
            'prettyPrint': 'false',
            ...?query,
          }),
          headers: {
            'User-Agent': _userAgent,
            'Content-Type': 'application/json',
            'Origin': 'https://music.youtube.com',
            'Accept': '*/*',
          },
          body: json.encode({
            'context': {
              'client': {
                'clientName': 'WEB_REMIX',
                'clientVersion': _clientVersion(),
                'hl': 'en',
                'gl': 'US',
              },
              'user': <String, dynamic>{},
            },
            ...body,
          }),
        )
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('YouTube Music HTTP ${resp.statusCode}');
    }
    // Decode explicitly: YouTube returns UTF-8, and `resp.body` would fall
    // back to latin1 when the charset is absent, mangling non-Latin titles.
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// The `clientVersion` the web client would send today ("1.<yyyymmdd>.01.00").
  static String _clientVersion() {
    final d = DateTime.now().toUtc();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '1.$y$m$day.01.00';
  }

  // --- Parsing (static: fixture-testable, no client needed) ---

  /// Picks the artist browseId out of a search response. Prefers the run
  /// whose text matches [name] exactly (normalized); otherwise the most
  /// frequent artist browseId across the results.
  static String? artistIdFromJson(Map<String, dynamic> data, String name) {
    final target = _normalize(name);
    if (target.isEmpty) return null;
    final counts = <String, int>{};
    for (final item in _songItems(data)) {
      for (final run in _artistRuns(item)) {
        final id = _browseIdOf(run);
        if (id == null || id.isEmpty) continue;
        final text = run['text'];
        if (text is String && _normalize(text) == target) return id;
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    String? best;
    var bestCount = 0;
    counts.forEach((id, count) {
      if (count > bestCount) {
        best = id;
        bestCount = count;
      }
    });
    return best;
  }

  /// Maps the artist `browse` response to name, image, songs and releases.
  static ArtistPage parseArtistJson(Map<String, dynamic> data) {
    final header = _findFirst(data, 'musicImmersiveHeaderRenderer') ??
        _findFirst(data, 'musicHeaderRenderer');
    return ArtistPage(
      name: _titleText(header) ?? '',
      imageUrl: header == null ? null : _bestThumb(header),
      songs: _shelfSongs(data),
      albums: _albumCards(data),
      songsBrowseId: _songsBrowseId(data),
    );
  }

  /// The "Songs" shelf only shows a preview; its title / "More" link points at
  /// a playlist-style browse (`VL…`) that lists every song by the artist.
  static String? _songsBrowseId(Map data) {
    for (final key in const [
      'musicShelfRenderer',
      'musicCarouselShelfRenderer'
    ]) {
      for (final shelf in _findAll(data, key)) {
        final title = (_titleText(shelf) ??
                _titleText(_findFirst(
                    shelf, 'musicCarouselShelfBasicHeaderRenderer')) ??
                '')
            .toLowerCase();
        if (!title.contains('song')) continue;
        for (final node in [
          shelf['title'],
          shelf['header'],
          shelf['bottomEndpoint'],
          shelf['moreContentButton'],
        ]) {
          for (final endpoint in _findAll(node, 'browseEndpoint')) {
            final id = _string(endpoint, 'browseId');
            if (id != null && id.startsWith('VL')) return id;
          }
        }
      }
    }
    return null;
  }

  /// Next-page token of a `browse` response (playlist-style lists).
  static String? _continuationOf(Map data) {
    for (final node in _findAll(data, 'nextContinuationData')) {
      final token = _string(node, 'continuation');
      if (token != null) return token;
    }
    for (final node in _findAll(data, 'continuationCommand')) {
      final token = _string(node, 'token');
      if (token != null) return token;
    }
    return null;
  }

  /// Maps a `next` (watch / radio) response to its "Up next" tracks in
  /// YouTube's order. The queue lives in `playlistPanelRenderer`; a wrapped
  /// renderer (`playlistPanelVideoWrapperRenderer`) is walked by [_findAll],
  /// which still sees the primary entry once.
  static List<Song> parseRadioJson(Map<String, dynamic> data,
      {int limit = 30}) {
    final out = <Song>[];
    final seen = <String>{};
    for (final item in _findAll(data, 'playlistPanelVideoRenderer')) {
      if (out.length >= limit) break;
      final videoId = _string(item, 'videoId');
      if (videoId == null || videoId.isEmpty) continue;
      if (!seen.add(videoId)) continue;
      final title = _titleText(item);
      if (title == null) continue;
      final artist = _byline(item);
      final duration = _clock(item['lengthText']);
      out.add(Song(
        id: videoId,
        title: title,
        artist: artist.isEmpty ? 'Unknown' : artist,
        thumbnailUrl: _plainThumb(item['thumbnail']) ??
            'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
        duration: duration,
        videoId: videoId,
        channel: artist,
      ));
    }
    return out;
  }

  /// Maps an album `browse` response to its tracks. Falls back to any
  /// responsive rows when the layout has no `musicShelfRenderer`.
  static List<Song> parseAlbumJson(Map<String, dynamic> data) {
    final songs = _shelfSongs(data);
    if (songs.isNotEmpty) return songs;
    final out = <Song>[];
    final seen = <String>{};
    for (final renderer in _findAll(data, 'musicResponsiveListItemRenderer')) {
      final song = _toSong(renderer);
      if (song != null && seen.add(song.videoId ?? song.id)) out.add(song);
    }
    return out;
  }

  /// Tracks every `musicShelfRenderer` (artist "Songs" shelf, album track
  /// list) and `musicPlaylistShelfRenderer` (full song list) through the same
  /// row parser search uses.
  static List<Song> _shelfSongs(Map data) {
    final out = <Song>[];
    final seen = <String>{};
    void add(List<dynamic> contents) {
      for (final raw in contents) {
        if (raw is! Map) continue;
        final renderer = raw['musicResponsiveListItemRenderer'];
        if (renderer is! Map) continue;
        final song = _toSong(renderer);
        if (song != null && seen.add(song.videoId ?? song.id)) out.add(song);
      }
    }

    for (final key in const [
      'musicShelfRenderer',
      'musicPlaylistShelfRenderer',
      'musicPlaylistShelfContinuation',
    ]) {
      for (final shelf in _findAll(data, key)) {
        final contents = shelf['contents'];
        if (contents is List) add(contents);
      }
    }
    // Continuation pages have no shelf wrapper: rows sit directly under
    // appendContinuationItemsAction.continuationItems. Without this the list
    // stops at the first page (≤100 songs for popular artists).
    for (final action in _findAll(data, 'appendContinuationItemsAction')) {
      final items = action['continuationItems'];
      if (items is List) add(items);
    }
    return out;
  }

  /// Collects album/single carousel cards. Only carousels titled "Albums" /
  /// "Singles" / "EP" count, so "Related artists" and "Videos" are skipped.
  static List<AlbumRef> _albumCards(Map data) {
    final out = <AlbumRef>[];
    final seen = <String>{};
    for (final carousel in _findAll(data, 'musicCarouselShelfRenderer')) {
      final title = (_titleText(_findFirst(
                  carousel, 'musicCarouselShelfBasicHeaderRenderer')) ??
              '')
          .toLowerCase();
      if (!(title.contains('album') ||
          title.contains('single') ||
          title.contains('ep'))) {
        continue;
      }
      final contents = carousel['contents'];
      if (contents is! List) continue;
      for (final raw in contents) {
        if (raw is! Map) continue;
        final item = raw['musicTwoRowItemRenderer'];
        if (item is! Map) continue;
        final browseId = _browseIdOf(item);
        final cardTitle = _titleText(item);
        if (browseId == null || cardTitle == null) continue;
        if (!seen.add(browseId)) continue;
        out.add(AlbumRef(
          title: cardTitle,
          year: _yearOf(item),
          browseId: browseId,
          thumbnailUrl: _bestThumb(item),
        ));
      }
    }
    return out;
  }

  /// Walks the response to the `musicResponsiveListItemRenderer` entries of
  /// every songs shelf. Filtered searches come back under
  /// `tabbedSearchResultsRenderer`; the plain shape is handled too. Every tab
  /// is read, not just the first: an unfiltered search carries the song rows
  /// and the upload rows in different tabs.
  static Iterable<Map> _songItems(Map<String, dynamic> data) sync* {
    // Continuation pages carry no top-level `contents`: the rows sit under
    // continuationContents.musicShelfContinuation.contents (or the playlist
    // shelf variant). Without this shape every "next page" parsed as empty.
    final continuation = data['continuationContents'];
    if (continuation is Map) {
      for (final key in const [
        'musicShelfContinuation',
        'musicPlaylistShelfContinuation',
      ]) {
        final items = _dig(continuation, [key, 'contents']) as List?;
        if (items == null) continue;
        for (final raw in items) {
          if (raw is! Map) continue;
          final renderer = raw['musicResponsiveListItemRenderer'];
          if (renderer is Map) yield renderer;
        }
      }
    }
    final contents = data['contents'];
    if (contents is! Map) return;

    final sections = <List<dynamic>>[];
    final tabbed = contents['tabbedSearchResultsRenderer'];
    if (tabbed is Map) {
      final tabs = tabbed['tabs'];
      if (tabs is List) {
        for (final tab in tabs) {
          final list = _dig(tab, [
            'tabRenderer',
            'content',
            'sectionListRenderer',
            'contents',
          ]) as List?;
          if (list != null) sections.add(list);
        }
      }
    } else {
      final sectionList = contents['sectionListRenderer'];
      if (sectionList is Map) {
        final list = sectionList['contents'] as List?;
        if (list != null) sections.add(list);
      }
    }

    for (final list in sections) {
      for (final section in list) {
        if (section is! Map) continue;
        final shelf = section['musicShelfRenderer'];
        if (shelf is! Map) continue;
        final items = shelf['contents'];
        if (items is! List) continue;
        for (final raw in items) {
          if (raw is! Map) continue;
          final renderer = raw['musicResponsiveListItemRenderer'];
          if (renderer is Map) yield renderer;
        }
      }
    }
    // Continuation pages have no shelf wrapper: the rows sit directly under
    // appendContinuationItemsAction.continuationItems. Without this the list
    // stops at the end of the first page.
    for (final action in _findAll(data, 'appendContinuationItemsAction')) {
      final items = action['continuationItems'];
      if (items is! List) continue;
      for (final raw in items) {
        if (raw is! Map) continue;
        final renderer = raw['musicResponsiveListItemRenderer'];
        if (renderer is Map) yield renderer;
      }
    }
  }

  static Song? _toSong(Map item) {
    final flex = item['flexColumns'];
    if (flex is! List || flex.isEmpty) return null;

    final title = _text(flex[0]);
    if (title == null || title.isEmpty) return null;

    final videoId = _watchId(flex[0]) ??
        _string(item['playlistItemData'], 'videoId') ??
        _overlayId(item);
    if (videoId == null || videoId.isEmpty) return null;

    final runs = _runs(flex.length > 1 ? flex[1] : null);
    final artist = _artistFrom(runs);
    final duration = _durationFrom(runs);
    return Song(
      id: videoId,
      title: title,
      artist: artist.isEmpty ? 'Unknown' : artist,
      thumbnailUrl:
          _thumb(item) ?? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      // Rows that carry the length in a separate column instead of the
      // subtitle would otherwise show no length at all.
      duration: duration > Duration.zero ? duration : _fixedLength(item),
      videoId: videoId,
      channel: artist,
    );
  }

  /// Length from the row's fixed column ("3:45"), used when the subtitle
  /// runs carry none.
  /// Rows use either a single `fixedColumn` or a `fixedColumns` list of
  /// `musicResponsiveListItemFixedColumnRenderer` entries. Reading only the
  /// singular key left most album/artist rows at 0:00.
  static Duration _fixedLength(Map item) {
    final columns = item['fixedColumn'] ?? item['fixedColumns'];
    if (columns is List) {
      for (final column in columns) {
        final d = _fixedColumnDuration(column);
        if (d > Duration.zero) return d;
      }
      return Duration.zero;
    }
    return _fixedColumnDuration(columns);
  }

  static Duration _fixedColumnDuration(Object? column) {
    if (column is! Map) return Duration.zero;
    final inner = _map(column, 'musicResponsiveListItemFixedColumnRenderer') ??
        _map(column, 'musicFixedColumnsRenderer') ??
        column;
    final text = _map(_map(inner, 'fixedColumn') ?? inner, 'text');
    if (text is! Map) return Duration.zero;
    String? raw = text['simpleText'] as String?;
    final runs = text['runs'];
    if (raw == null && runs is List && runs.isNotEmpty) {
      final first = runs.first;
      if (first is Map) raw = first['text'] as String?;
    }
    if (raw == null) return Duration.zero;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw.trim());
    if (m == null) return Duration.zero;
    return Duration(
        minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!));
  }

  /// Artist runs = subtitle runs up to the first "•" separator. Read during
  /// discovery so album/related runs do not leak into the browseId vote.
  static List<Map> _artistRuns(Map item) {
    final flex = item['flexColumns'];
    if (flex is! List || flex.length < 2) return const [];
    final out = <Map>[];
    for (final run in _runs(flex[1])) {
      final text = run['text'];
      if (text is String && text.trim() == '•') break;
      out.add(run);
    }
    return out;
  }

  /// The renderer of a flex column ("text" node with runs).
  static Map? _renderer(dynamic column) {
    if (column is! Map) return null;
    final r = column['musicResponsiveListItemFlexColumnRenderer'];
    return r is Map ? r : null;
  }

  static List<Map> _runs(dynamic column) {
    final text = _renderer(column)?['text'];
    if (text is! Map) return const [];
    final runs = text['runs'];
    if (runs is! List) return const [];
    return runs.whereType<Map>().toList();
  }

  static String? _text(dynamic column) {
    final runs = _runs(column);
    if (runs.isEmpty) return null;
    final b = StringBuffer();
    for (final run in runs) {
      final t = run['text'];
      if (t is String) b.write(t);
    }
    final out = b.toString().trim();
    return out.isEmpty ? null : out;
  }

  static String? _watchId(dynamic column) {
    for (final run in _runs(column)) {
      final endpoint = run['navigationEndpoint'];
      if (endpoint is Map) {
        final id = _string(endpoint['watchEndpoint'], 'videoId');
        if (id != null) return id;
      }
    }
    return null;
  }

  static String? _overlayId(Map item) {
    final overlay = _map(item['overlay'], 'musicItemThumbnailOverlayRenderer');
    final content = _map(overlay, 'content');
    final play = _map(content, 'musicPlayButtonRenderer');
    final endpoint = _map(play, 'playNavigationEndpoint');
    return _string(_map(endpoint, 'watchEndpoint'), 'videoId');
  }

  /// YouTube's video classification of a search row (OMV / UGC / ATV / …).
  /// It sits in the same overlay watchEndpoint [_overlayId] reads, one level
  /// deeper under `watchEndpointMusicSupportedConfigs`.
  static String? _videoType(Map item) {
    final overlay = _map(item['overlay'], 'musicItemThumbnailOverlayRenderer');
    final content = _map(overlay, 'content');
    final play = _map(content, 'musicPlayButtonRenderer');
    final endpoint = _map(play, 'playNavigationEndpoint');
    final watch = _map(endpoint, 'watchEndpoint');
    final configs = _map(watch, 'watchEndpointMusicSupportedConfigs');
    return _string(_map(configs, 'watchEndpointMusicConfig'), 'musicVideoType');
  }

  /// Artist(s) = subtitle runs up to the first "•" separator. The subtitle is
  /// "Artists • Album • Duration" (videos add a views segment).
  static String _artistFrom(List<Map> runs) {
    final b = StringBuffer();
    for (final run in runs) {
      final t = run['text'];
      if (t is! String) continue;
      if (t.trim() == '•') break;
      b.write(t);
    }
    return b.toString().trim();
  }

  static Duration _durationFrom(List<Map> runs) {
    final re = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$');
    Duration found = Duration.zero;
    for (final run in runs) {
      final t = run['text'];
      if (t is! String) continue;
      final m = re.firstMatch(t.trim());
      if (m == null) continue;
      if (m.group(3) != null) {
        found = Duration(
            hours: int.parse(m.group(1)!),
            minutes: int.parse(m.group(2)!),
            seconds: int.parse(m.group(3)!));
      } else {
        found = Duration(
            minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!));
      }
    }
    return found;
  }

  /// Artist(s) of a radio row: `longBylineText` then `shortBylineText`, up to
  /// the first "•" (the remainder is album/views).
  static String _byline(Map item) {
    for (final key in const ['longBylineText', 'shortBylineText']) {
      final b = StringBuffer();
      for (final run in _textRuns(item[key])) {
        final t = run['text'];
        if (t is! String) continue;
        if (t.trim() == '•') break;
        b.write(t);
      }
      final out = b.toString().trim();
      if (out.isNotEmpty) return out;
    }
    return '';
  }

  /// A clock value held as `simpleText` ("3:45") or runs.
  static Duration _clock(dynamic node) {
    if (node is! Map) return Duration.zero;
    var raw = node['simpleText'];
    if (raw is! String) {
      final runs = _textRuns(node);
      raw = runs.isEmpty ? null : runs.first['text'];
    }
    if (raw is! String) return Duration.zero;
    final m =
        RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(raw.trim());
    if (m == null) return Duration.zero;
    if (m.group(3) != null) {
      return Duration(
          hours: int.parse(m.group(1)!),
          minutes: int.parse(m.group(2)!),
          seconds: int.parse(m.group(3)!));
    }
    return Duration(
        minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!));
  }

  /// Runs of a plain `{runs: [...]}` text node (not a flex column).
  static List<Map> _textRuns(dynamic node) {
    if (node is! Map) return const [];
    final runs = node['runs'];
    if (runs is! List) return const [];
    return runs.whereType<Map>().toList();
  }

  static String? _plainThumb(dynamic node) {
    if (node is! Map) return null;
    final list = node['thumbnails'];
    if (list is! List) return null;
    return _largestImage(list);
  }

  static String? _thumb(Map item) {
    final renderer = _map(item['thumbnail'], 'musicThumbnailRenderer');
    final list = _map(renderer, 'thumbnail')?['thumbnails'];
    if (list is! List) return null;
    return _largestImage(list);
  }

  /// First `musicThumbnailRenderer` found anywhere inside [node], at the
  /// largest offered size. Used for header art and two-row release cards.
  static String? _bestThumb(Map node) {
    for (final renderer in _findAll(node, 'musicThumbnailRenderer')) {
      final list = _map(renderer, 'thumbnail')?['thumbnails'];
      if (list is! List) continue;
      final url = _largestImage(list);
      if (url != null) return url;
    }
    return null;
  }

  static String? _largestImage(List list) {
    String? url;
    var best = -1;
    for (final e in list) {
      if (e is! Map) continue;
      final w = (e['width'] as num?)?.toInt() ?? 0;
      final h = (e['height'] as num?)?.toInt() ?? 0;
      final u = e['url'];
      if (u is String && w * h >= best) {
        best = w * h;
        url = u;
      }
    }
    return url == null ? null : _upgradeGoogleImage(url);
  }

  /// First title found in a renderer shaped `title: {runs|simpleText}`.
  static String? _titleText(Map? node) {
    if (node == null) return null;
    final title = node['title'];
    if (title is String) {
      final t = title.trim();
      return t.isEmpty ? null : t;
    }
    if (title is! Map) return null;
    final runs = title['runs'];
    if (runs is List) {
      final b = StringBuffer();
      for (final run in runs) {
        if (run is Map) {
          final t = run['text'];
          if (t is String) b.write(t);
        }
      }
      final out = b.toString().trim();
      if (out.isNotEmpty) return out;
    }
    final simple = title['simpleText'];
    if (simple is String && simple.trim().isNotEmpty) return simple.trim();
    return null;
  }

  /// Four-digit year inside a two-row item's subtitle ("1995 • Album").
  static String? _yearOf(Map item) {
    final subtitle = item['subtitle'];
    if (subtitle is! Map) return null;
    final runs = subtitle['runs'];
    if (runs is! List) return null;
    for (final run in runs) {
      if (run is! Map) continue;
      final t = run['text'];
      if (t is String && RegExp(r'^\d{4}$').hasMatch(t.trim())) return t.trim();
    }
    return null;
  }

  /// Google's image CDN (`*.googleusercontent.com`) carries a size suffix
  /// (e.g. "=w120-h120-l90-rj"). The response only offers 60/120 px thumbs,
  /// but requesting a large square returns the real album art (verified
  /// 1080x1080) — essential for the full-screen player and the notification,
  /// which otherwise stretch a 120 px image.
  static String _upgradeGoogleImage(String url) {
    final eq = url.indexOf('=');
    if (eq <= 0) return url;
    final host = Uri.tryParse(url)?.host ?? '';
    if (!host.endsWith('googleusercontent.com')) return url;
    return '${url.substring(0, eq)}=w1080-h1080-l90-rj';
  }

  static String? _browseIdOf(dynamic node) {
    if (node is! Map) return null;
    final endpoint = node['navigationEndpoint'];
    if (endpoint is! Map) return null;
    final id = _string(endpoint['browseEndpoint'], 'browseId');
    return id;
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Unicode-aware match key for the video policy: ASCII-only [_normalize]
  /// erases Japanese/Korean/Cyrillic titles and rejects every candidate.
  static String _matchKey(String value) => _fold(value)
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  /// Every map value stored under [key], at any depth.
  static Iterable<Map> _findAll(dynamic node, String key) sync* {
    if (node is Map) {
      final value = node[key];
      if (value is Map) yield value;
      for (final child in node.values) {
        yield* _findAll(child, key);
      }
    } else if (node is List) {
      for (final child in node) {
        yield* _findAll(child, key);
      }
    }
  }

  static Map? _findFirst(dynamic node, String key) {
    for (final found in _findAll(node, key)) {
      return found;
    }
    return null;
  }

  static Map? _map(dynamic node, String key) {
    if (node is! Map) return null;
    final v = node[key];
    return v is Map ? v : null;
  }

  static String? _string(dynamic node, String key) {
    if (node is! Map) return null;
    final v = node[key];
    return v is String ? v : null;
  }

  static dynamic _dig(dynamic node, List<String> path) {
    var cur = node;
    for (final key in path) {
      if (cur is! Map) return null;
      cur = cur[key];
      if (cur == null) return null;
    }
    return cur;
  }

  /// Frees the underlying HTTP client.
  void dispose() => _client.close();
}
