import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';

/// Fetches playlist videos by parsing YouTube's playlist page.
///
/// youtube_explode_dart cannot parse playlists right now because YouTube
/// replaced `playlistVideoRenderer` items with `lockupViewModel` items.
/// This parser reads the new structure, including continuation pages.
///
/// Robustness matters more than elegance here: YouTube returns the same
/// playlist through different wrapper renderers (and alternates between
/// `onResponseReceivedActions` and `onResponseReceivedEndpoints` for
/// continuations), so a rigid path silently truncated imports to the first
/// page. The collector therefore accepts every known item shape and falls
/// back to walking the whole response, and continuation fetches retry
/// transient failures instead of dropping everything after page one.
class PlaylistParser {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const _timeout = Duration(seconds: 20);
  static const _maxContinuationFailures = 3;

  /// Testing hook for [_extractInitialData].
  @visibleForTesting
  static Map<String, dynamic> extractInitialDataForTest(String html) =>
      PlaylistParser()._extractInitialData(html);

  Future<List<Song>> fetchVideos(String playlistId, {int maxPages = 25}) async {
    final songs = <Song>[];
    final seen = <String>{};

    final html = await _getPage(playlistId);
    final data = _extractInitialData(html);
    final apiKey = _firstMatch(html, r'"INNERTUBE_API_KEY":"([^"]+)"');
    final clientVersion =
        _firstMatch(html, r'"INNERTUBE_CLIENT_VERSION":"([^"]+)"');

    String? token = _collect(data, songs, seen);
    var pages = 1;
    var failures = 0;
    while (token != null && token.isNotEmpty && pages < maxPages) {
      if (apiKey == null) {
        // A next page exists but the page HTML carried no continuation key:
        // fail loudly instead of silently returning only the first page.
        throw Exception('Playlist import could not continue: YouTube did '
            'not expose a continuation key.');
      }
      Map<String, dynamic> cont;
      try {
        cont = await _postContinuation(apiKey, clientVersion, token);
        failures = 0;
      } catch (_) {
        // A transient continuation failure must not drop the rest of the
        // playlist: retry the same token a few times before giving up.
        failures++;
        if (failures >= _maxContinuationFailures) break;
        await Future.delayed(Duration(milliseconds: 400 * failures));
        continue;
      }
      final previousToken = token;
      final before = songs.length;
      token = _collect(cont, songs, seen);
      pages++;
      // Guard against a page that neither adds songs nor advances the token
      // (otherwise the loop would spin until maxPages on a stuck response).
      if (token == previousToken && songs.length == before) break;
    }
    return songs;
  }

  Future<String> _getPage(String playlistId) async {
    final resp = await http
        .get(
          Uri.parse(
              'https://www.youtube.com/playlist?list=$playlistId&hl=en&persist_hl=1'),
          headers: {'User-Agent': _ua},
        )
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('Playlist page returned ${resp.statusCode}');
    }
    return resp.body;
  }

  Map<String, dynamic> _extractInitialData(String html) {
    // Find the assignment, then scan to the matching closing brace. A regex
    // cannot do this safely: non-greedy stops at the first `};` inside a
    // string value, and `.` does not match newlines in a non-minified page.
    final marker = RegExp(r'ytInitialData\s*=\s*').firstMatch(html);
    if (marker == null) throw Exception('Playlist data not found on page');
    final start = html.indexOf('{', marker.end);
    if (start < 0) throw Exception('Playlist data not found on page');
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < html.length; i++) {
      final ch = html[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          final raw = html.substring(start, i + 1);
          return json.decode(raw) as Map<String, dynamic>;
        }
      }
    }
    throw Exception('Playlist data not found on page');
  }

  String? _firstMatch(String text, String pattern) {
    return RegExp(pattern).firstMatch(text)?.group(1);
  }

  /// Safe string read: a non-string JSON value yields null instead of
  /// throwing and aborting the whole import.
  static String? _asString(dynamic value) => value is String ? value : null;

  Future<Map<String, dynamic>> _postContinuation(
      String apiKey, String? clientVersion, String token) async {
    final resp = await http
        .post(
          Uri.parse(
              'https://www.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false'),
          headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
          body: json.encode({
            'context': {
              'client': {
                'clientName': 'WEB',
                'clientVersion': clientVersion ?? '2.20250222',
                'hl': 'en',
                'gl': 'US',
              }
            },
            'continuation': token,
          }),
        )
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('Continuation returned ${resp.statusCode}');
    }
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  /// Collects songs from a response map. Returns next continuation token.
  String? _collect(
      Map<String, dynamic> data, List<Song> out, Set<String> seen) {
    final items = _findItems(data);
    String? token = _collectItems(items, out, seen);
    if (token != null) return token;
    // Fallback: when the expected wrapper is missing (or the items carry no
    // continuation token), walk the whole document so a shape change can
    // never silently truncate an import.
    final ref = _TokenRef();
    _walk(data, out, seen, ref);
    return ref.value;
  }

  String? _collectItems(
      List<dynamic> items, List<Song> out, Set<String> seen) {
    String? token;
    for (final item in items) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final song = _songFromItem(map);
      if (song != null && seen.add(song.videoId ?? song.id)) {
        out.add(song);
      }
      final t = _tokenFromItem(map);
      if (t != null) token = t;
    }
    return token;
  }

  /// Depth-first scan that picks up items and the first continuation token
  /// regardless of the renderer that wraps them. [seen] dedups.
  void _walk(
      dynamic node, List<Song> out, Set<String> seen, _TokenRef token) {
    if (node is List) {
      for (final e in node) {
        _walk(e, out, seen, token);
      }
      return;
    }
    if (node is! Map) return;
    final map = node.cast<String, dynamic>();
    final song = _songFromItem(map);
    if (song != null && seen.add(song.videoId ?? song.id)) out.add(song);
    if (token.value == null) {
      final t = _tokenFromItem(map);
      if (t != null) token.value = t;
    }
    for (final v in map.values) {
      _walk(v, out, seen, token);
    }
  }

  Song? _songFromItem(Map<String, dynamic> map) {
    if (map.containsKey('lockupViewModel')) {
      return _parseLockup(map['lockupViewModel']);
    }
    if (map.containsKey('playlistVideoRenderer')) {
      return _parseLegacy(map['playlistVideoRenderer']);
    }
    return null;
  }

  String? _tokenFromItem(Map<String, dynamic> map) {
    if (!_isContinuationItem(map)) return null;
    return _findToken(map);
  }

  bool _isContinuationItem(Map<dynamic, dynamic> map) =>
      map.containsKey('continuationItemRenderer') ||
      map.containsKey('continuationItemViewModel');

  /// Finds a `continuationCommand.token` anywhere inside [node]. The token is
  /// nested differently between the legacy `continuationItemRenderer` and the
  /// newer `continuationItemViewModel` (which wraps it one level deeper), so
  /// search rather than assume a path.
  String? _findToken(dynamic node) {
    if (node is Map) {
      final cmd = node['continuationCommand'];
      if (cmd is Map && cmd['token'] is String) return cmd['token'] as String;
      for (final v in node.values) {
        final t = _findToken(v);
        if (t != null) return t;
      }
    } else if (node is List) {
      for (final e in node) {
        final t = _findToken(e);
        if (t != null) return t;
      }
    }
    return null;
  }

  List<dynamic> _findItems(Map<String, dynamic> data) {
    // Continuation responses: two wrapper keys and two command names, all
    // seen in the wild.
    for (final key in const [
      'onResponseReceivedActions',
      'onResponseReceivedEndpoints',
    ]) {
      final list = data[key];
      if (list is! List) continue;
      for (final action in list) {
        if (action is! Map) continue;
        for (final cmdKey in const [
          'appendContinuationItemsAction',
          'reloadContinuationItemsCommand',
        ]) {
          final cmd = action[cmdKey];
          if (cmd is Map && cmd['continuationItems'] is List) {
            return cmd['continuationItems'] as List;
          }
        }
      }
    }
    // First page: find the renderer list wherever YouTube nests it
    // (itemSectionRenderer, playlistVideoListRenderer, musicPlaylistShelf…).
    return _findItemList(data) ?? const [];
  }

  List<dynamic>? _findItemList(dynamic node) {
    if (node is List) {
      if (node.isNotEmpty &&
          node.every((e) => e is Map) &&
          node.any((e) => _isPlaylistItem(e as Map))) {
        return node;
      }
      for (final e in node) {
        final found = _findItemList(e);
        if (found != null) return found;
      }
    } else if (node is Map) {
      for (final v in node.values) {
        final found = _findItemList(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  bool _isPlaylistItem(Map<dynamic, dynamic> map) =>
      map.containsKey('lockupViewModel') ||
      map.containsKey('playlistVideoRenderer');

  Song? _parseLockup(dynamic vm) {
    if (vm is! Map) return null;
    final map = vm.cast<String, dynamic>();
    if (map['contentType'] != 'LOCKUP_CONTENT_TYPE_VIDEO') return null;

    String? videoId = _asString(map['contentId']);

    String? titleText;
    final meta = map['metadata'];
    if (meta is Map) {
      final lmm = meta['lockupMetadataViewModel'];
      if (lmm is Map) {
        final title = lmm['title'];
        if (title is Map) titleText = _asString(title['content']);
      }
    }

    String artist = '';
    try {
      final metaMap = map['metadata'];
      if (metaMap is Map) {
        final lmm = metaMap['lockupMetadataViewModel'];
        if (lmm is Map) {
          final md = lmm['metadata'];
          if (md is Map) {
            final cmvm = md['contentMetadataViewModel'];
            if (cmvm is Map) {
              final rows = cmvm['metadataRows'];
              if (rows is List && rows.isNotEmpty && rows.first is Map) {
                final parts = (rows.first as Map)['metadataParts'];
                if (parts is List && parts.isNotEmpty && parts.first is Map) {
                  final text = (parts.first as Map)['text'];
                  if (text is Map) {
                    artist = (text['content'] as String?) ?? '';
                  }
                }
              }
            }
          }
        }
      }
    } catch (_) {
      artist = '';
    }

    Duration duration = Duration.zero;
    String? thumbUrl;
    try {
      final ci = map['contentImage'];
      if (ci is Map) {
        final tvm = ci['thumbnailViewModel'];
        if (tvm is Map) {
          final overlays = tvm['overlays'];
          if (overlays is List) {
            for (final o in overlays) {
              if (o is! Map) continue;
              final tbovm = o['thumbnailBottomOverlayViewModel'];
              if (tbovm is! Map) continue;
              final badges = tbovm['badges'];
              if (badges is! List) continue;
              for (final b in badges) {
                if (b is! Map) continue;
                final bvm = b['thumbnailBadgeViewModel'];
                if (bvm is! Map) continue;
                final text = bvm['text'];
                if (text is String &&
                    RegExp(r'^[\d:]+$').hasMatch(text)) {
                  duration = _parseDuration(text);
                }
              }
            }
          }
          final img = tvm['image'];
          if (img is Map) {
            final sources = img['sources'];
            if (sources is List && sources.isNotEmpty) {
              // Sources are ordered by size; take the largest so the art is
              // not shown from a ~120px thumb before the resolver upgrades it.
              Map? best;
              var bestW = -1;
              for (final s in sources) {
                if (s is! Map) continue;
                final w = (s['width'] as num?)?.toInt() ?? 0;
                if (best == null || w >= bestW) {
                  best = s;
                  bestW = w;
                }
              }
              thumbUrl = best?['url'] as String?;
            }
          }
        }
      }
    } catch (_) {
      // Keep defaults.
    }

    videoId ??= _firstMatch(
        thumbUrl ?? '', r'i\.ytimg\.com/vi/([^/]+)/');
    if (videoId == null || videoId.isEmpty) return null;

    return Song(
      id: videoId,
      title: (titleText == null || titleText.isEmpty) ? videoId : titleText,
      artist: artist.isEmpty ? 'Unknown' : artist,
      thumbnailUrl:
          thumbUrl ?? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      duration: duration,
      videoId: videoId,
      channel: artist,
    );
  }

  /// Legacy `playlistVideoRenderer` item (still served for some playlists).
  Song? _parseLegacy(dynamic vm) {
    if (vm is! Map) return null;
    final map = vm.cast<String, dynamic>();
    final videoId = _asString(map['videoId']);
    if (videoId == null || videoId.isEmpty) return null;

    String title = videoId;
    final t = map['title'];
    if (t is Map) {
      final simple = t['simpleText'];
      if (simple is String && simple.isNotEmpty) {
        title = simple;
      } else {
        final runs = t['runs'];
        if (runs is List && runs.isNotEmpty && runs.first is Map) {
          title = _asString((runs.first as Map)['text']) ?? title;
        }
      }
    }

    String artist = '';
    final owner = map['shortBylineText'] ?? map['longBylineText'];
    if (owner is Map) {
      final runs = owner['runs'];
      if (runs is List && runs.isNotEmpty && runs.first is Map) {
        artist = _asString((runs.first as Map)['text']) ?? '';
      } else if (owner['simpleText'] is String) {
        artist = owner['simpleText'] as String;
      }
    }

    Duration duration = Duration.zero;
    final len = map['lengthText'];
    if (len is Map && len['simpleText'] is String) {
      duration = _parseDuration(len['simpleText'] as String);
    }

    return Song(
      id: videoId,
      title: title.isEmpty ? videoId : title,
      artist: artist.isEmpty ? 'Unknown' : artist,
      thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      duration: duration,
      videoId: videoId,
      channel: artist,
    );
  }

  Duration _parseDuration(String text) {
    try {
      final parts =
          text.split(':').map((p) => int.parse(p.trim())).toList();
      if (parts.length == 3) {
        return Duration(
            hours: parts[0], minutes: parts[1], seconds: parts[2]);
      }
      if (parts.length == 2) {
        return Duration(minutes: parts[0], seconds: parts[1]);
      }
      if (parts.length == 1) return Duration(seconds: parts[0]);
    } catch (_) {
      // Fall through.
    }
    return Duration.zero;
  }
}

/// Mutable single-value holder used by the recursive walker.
class _TokenRef {
  String? value;
}
