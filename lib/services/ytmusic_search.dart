import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/artist.dart';
import '../models/song.dart';

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
  static const String _searchUrl =
      'https://music.youtube.com/youtubei/v1/search';
  static const String _browseUrl =
      'https://music.youtube.com/youtubei/v1/browse';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) '
      'Gecko/20100101 Firefox/88.0';

  /// `get_search_params(filter="songs")` = "EgWKAQ" + "II" + "AWoMEA…".
  static const String _songsParams = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';

  final http.Client _client;

  /// Songs only (no music videos). Returns an empty list when the query has
  /// no song entries — callers may fall back to video results.
  Future<List<Song>> searchSongs(String query, {int limit = 20}) =>
      _search(query, _songsParams, limit: limit);

  Future<List<Song>> _search(
    String query,
    String params, {
    required int limit,
  }) async {
    final body = <String, dynamic>{'query': query};
    if (params.isNotEmpty) body['params'] = params;
    final data = await _post(_searchUrl, body);
    final songs = <Song>[];
    for (final item in _songItems(data)) {
      if (songs.length >= limit) break;
      final song = _toSong(item);
      if (song != null) songs.add(song);
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
      final next = await _post(_browseUrl, const {},
          query: {'ctoken': token, 'continuation': token});
      for (final song in _shelfSongs(next)) {
        if (seen.add(song.videoId ?? song.id)) out.add(song);
      }
      token = _continuationOf(next);
    }
    return out;
  }

  Future<Map<String, dynamic>> _post(
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
    for (final key in const ['musicShelfRenderer', 'musicCarouselShelfRenderer']) {
      for (final shelf in _findAll(data, key)) {
        final title = (_titleText(shelf) ??
                _titleText(_findFirst(shelf, 'musicCarouselShelfBasicHeaderRenderer')) ??
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
    for (final key in const [
      'musicShelfRenderer',
      'musicPlaylistShelfRenderer',
      'musicPlaylistShelfContinuation',
    ]) {
      for (final shelf in _findAll(data, key)) {
        final contents = shelf['contents'];
        if (contents is! List) continue;
        for (final raw in contents) {
          if (raw is! Map) continue;
          final renderer = raw['musicResponsiveListItemRenderer'];
          if (renderer is! Map) continue;
          final song = _toSong(renderer);
          if (song != null && seen.add(song.videoId ?? song.id)) out.add(song);
        }
      }
    }
    return out;
  }

  /// Collects album/single carousel cards. Only carousels titled "Albums" /
  /// "Singles" / "EP" count, so "Related artists" and "Videos" are skipped.
  static List<AlbumRef> _albumCards(Map data) {
    final out = <AlbumRef>[];
    final seen = <String>{};
    for (final carousel in _findAll(data, 'musicCarouselShelfRenderer')) {
      final title = (_titleText(
                  _findFirst(carousel, 'musicCarouselShelfBasicHeaderRenderer')) ??
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
  /// `tabbedSearchResultsRenderer`; the plain shape is handled too.
  static Iterable<Map> _songItems(Map<String, dynamic> data) sync* {
    final contents = data['contents'];
    if (contents is! Map) return;

    List<dynamic>? sections;
    final tabbed = contents['tabbedSearchResultsRenderer'];
    if (tabbed is Map) {
      final tabs = tabbed['tabs'];
      if (tabs is List && tabs.isNotEmpty) {
        sections = _dig(tabs.first, [
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents',
        ]) as List?;
      }
    } else {
      final sectionList = contents['sectionListRenderer'];
      if (sectionList is Map) sections = sectionList['contents'] as List?;
    }
    if (sections == null) return;

    for (final section in sections) {
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
    return Song(
      id: videoId,
      title: title,
      artist: artist.isEmpty ? 'Unknown' : artist,
      thumbnailUrl:
          _thumb(item) ?? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      duration: _durationFrom(runs),
      videoId: videoId,
      channel: artist,
    );
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
