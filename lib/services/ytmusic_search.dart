import 'dart:convert';

import 'package:http/http.dart' as http;

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
/// The request shape (client context, endpoint, filter params) mirrors what
/// sigma67's ytmusicapi sends. No auth is needed for public search.
class YouTubeMusicSearch {
  YouTubeMusicSearch({http.Client? client})
      : _client = client ?? http.Client();

  static const Duration _timeout = Duration(seconds: 20);
  static const String _base =
      'https://music.youtube.com/youtubei/v1/search';
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
    final resp = await _client
        .post(
          Uri.parse('$_base?alt=json&prettyPrint=false'),
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
            'query': query,
            'params': params,
          }),
        )
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('YouTube Music search HTTP ${resp.statusCode}');
    }
    // Decode explicitly: YouTube returns UTF-8, and `resp.body` would fall
    // back to latin1 when the charset is absent, mangling non-Latin titles.
    final data =
        json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final songs = <Song>[];
    for (final item in _songItems(data)) {
      if (songs.length >= limit) break;
      final song = _toSong(item);
      if (song != null) songs.add(song);
    }
    return songs;
  }

  /// The `clientVersion` the web client would send today ("1.<yyyymmdd>.01.00").
  static String _clientVersion() {
    final d = DateTime.now().toUtc();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '1.$y$m$day.01.00';
  }

  /// Walks the response to the `musicResponsiveListItemRenderer` entries of
  /// every songs shelf. Filtered searches come back under
  /// `tabbedSearchResultsRenderer`; the plain shape is handled too.
  Iterable<Map> _songItems(Map<String, dynamic> data) sync* {
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

  Song? _toSong(Map item) {
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
      thumbnailUrl: _thumb(item) ?? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      duration: _durationFrom(runs),
      videoId: videoId,
      channel: artist,
    );
  }

  /// The renderer of a flex column ("text" node with runs).
  Map? _renderer(dynamic column) {
    if (column is! Map) return null;
    final r = column['musicResponsiveListItemFlexColumnRenderer'];
    return r is Map ? r : null;
  }

  List<Map> _runs(dynamic column) {
    final text = _renderer(column)?['text'];
    if (text is! Map) return const [];
    final runs = text['runs'];
    if (runs is! List) return const [];
    return runs.whereType<Map>().toList();
  }

  String? _text(dynamic column) {
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

  String? _watchId(dynamic column) {
    for (final run in _runs(column)) {
      final endpoint = run['navigationEndpoint'];
      if (endpoint is Map) {
        final id = _string(endpoint['watchEndpoint'], 'videoId');
        if (id != null) return id;
      }
    }
    return null;
  }

  String? _overlayId(Map item) {
    final overlay = _map(item['overlay'], 'musicItemThumbnailOverlayRenderer');
    final content = _map(overlay, 'content');
    final play = _map(content, 'musicPlayButtonRenderer');
    final endpoint = _map(play, 'playNavigationEndpoint');
    return _string(_map(endpoint, 'watchEndpoint'), 'videoId');
  }

  /// Artist(s) = subtitle runs up to the first "•" separator. The subtitle is
  /// "Artists • Album • Duration" (videos add a views segment).
  String _artistFrom(List<Map> runs) {
    final b = StringBuffer();
    for (final run in runs) {
      final t = run['text'];
      if (t is! String) continue;
      if (t.trim() == '•') break;
      b.write(t);
    }
    return b.toString().trim();
  }

  Duration _durationFrom(List<Map> runs) {
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

  String? _thumb(Map item) {
    final renderer = _map(item['thumbnail'], 'musicThumbnailRenderer');
    final list = _map(renderer, 'thumbnail')?['thumbnails'];
    if (list is! List) return null;
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

  /// Google's image CDN (`*.googleusercontent.com`) carries a size suffix
  /// (e.g. "=w120-h120-l90-rj"). The search response only offers 60/120 px
  /// thumbs, but requesting a large square returns the real album art
  /// (verified 1080x1080) — essential for the full-screen player and the
  /// notification, which otherwise stretch a 120 px image.
  static String _upgradeGoogleImage(String url) {
    final eq = url.indexOf('=');
    if (eq <= 0) return url;
    final host = Uri.tryParse(url)?.host ?? '';
    if (!host.endsWith('googleusercontent.com')) return url;
    return '${url.substring(0, eq)}=w1080-h1080-l90-rj';
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
