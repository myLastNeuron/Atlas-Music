import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../../models/song.dart';
import '../media_source.dart';
import '../media_resolver.dart';
import '../resolve_failure.dart';

/// Sole owner of `youtube_explode_dart` (3.1.0, pinned) and of all
/// googlevideo range semantics. If YouTube changes InnerTube tomorrow,
/// only this file changes.
///
/// Client: VISIONOS (vendored below). Android/ANDROID clients trigger the
/// "downloaded this stream too many times" throttle that 403s googlevideo
/// after a few ranged requests — the exact failure on throttled networks.
/// VisionOS is a non-Android Apple client, no POT requirement, not subject
/// to that throttle. Same idea as the Harmony-Music fork of the library.
/// ANDROID_VR runs only if VISIONOS stalls or is gated, each under its own
/// short budget. Both carry a per-run `visitorData` token: without it,
/// bot-gated IPs (UK/EU) refuse every client with LOGIN_REQUIRED.
///
/// Ranking (deterministic, documented):
///  1. Compatible container/codec first: MP4/AAC (`mp4a`) beats Opus/WebM.
///     Reason: ExoPlayer handles both, but AAC-in-MP4 survives more
///     network stacks, proxies and download-then-play paths.
///  2. Within one codec family: highest bitrate first. (The library's
///     `sortByBitrate()` already returns highest-first despite its doc
///     comment; we keep that order, we do NOT pick `.last`.)
///  3. Streams with known non-zero content length beat unknown ones.
///  4. Absolute quality last: a reliable 48kbps AAC wins over an
///     unreliable 160kbps opus. Reliability is established by [validate].
class YouTubeProvider extends MediaResolver {
  /// Per-client and total budgets for one manifest resolve. One stalled
  /// client must not eat the whole budget: the old single 30s wrapper died
  /// on the first (watch-page) request in the UK.
  static const _perClientManifestBudget = Duration(seconds: 10);
  static const _manifestBudget = Duration(seconds: 25);

  /// Download chunk size. 1MB BY MEASUREMENT (live probe 2026-09):
  /// throttled ANDROID URLs 403 open-ended and 10MB ranges, 206 ≤1MB.
  /// Static + tested so nobody "upgrades" it back to library-style 10MB.
  static const downloadChunkBytes = 1024 * 1024;

  // Fresh connection per request: a middlebox/ISP that closes idle
  // keep-alive sockets made dart:io reuse a dead connection, which surfaced
  // as `Connection closed while receiving data` and then poisoned every
  // subsequent request — the whole queue failed to resolve (`resolve failed
  // ... attempts=2`, preloads `unresolvable`). Disabling keep-alive costs a
  // handshake per request but removes the dead-socket reuse entirely.
  final YoutubeExplode _yt =
      YoutubeExplode(httpClient: YoutubeHttpClient(_FreshConnectionClient()));
  final http.Client _http = _FreshConnectionClient();

  /// Optional staleness check callback. If provided, called during long
  /// operations (resolve/download) to check if the load has been superseded.
  /// Defaults to always returning false (never stale). Mutable so the owner
  /// can point it at the live playback generation — a hard-wired
  /// `() => false` made the abort hook dead code.
  bool Function()? stale;

  YouTubeProvider({this.stale});

  /// Manifest cache: one InnerTube player call serves resolve, retries,
  /// downloads, and replays of the same video. Without it every retry
  /// re-hits the API and a 429 spiral takes playback down entirely.
  final Map<String, _CachedManifest> _manifests = {};
  static const _manifestTtl = Duration(minutes: 20);

  /// Converts an exception to a [FailureScope].
  /// Network/DNS/timeout errors -> provider scope (affects all songs).
  /// Other errors -> song scope (isolated to this video).
  FailureScope _scopeFor(Object e) {
    final t = e.toString().toLowerCase();
    if (t.contains('socket') ||
        t.contains('dns') ||
        t.contains('host lookup') ||
        t.contains('unreachable') ||
        t.contains('connection') ||
        t.contains('timeout') ||
        t.contains('429') ||
        t.contains('rate limit') ||
        t.contains('503') ||
        t.contains('502') ||
        t.contains('504')) {
      return FailureScope.provider;
    }
    return FailureScope.song;
  }

  /// Ranks audio streams by quality: codec compatibility > bitrate > reliability.
  /// Prefers MP4/AAC (mp4a) over Opus/WebM for ExoPlayer compatibility.
  /// Falls back to unsorted audioOnly if sorting fails.
  static List<AudioOnlyStreamInfo> rankAudio(StreamManifest manifest) {
    final audio = manifest.audioOnly;
    if (audio.isEmpty) return [];
    try {
      // Sort: MP4/AAC first (mp4a), then by bitrate descending, then known content-length.
      audio.sort((a, b) {
        final aCodec = a.codec.toString().toLowerCase();
        final bCodec = b.codec.toString().toLowerCase();
        final aIsAac =
            aCodec.contains('mp4a') || a.container.name.toLowerCase() == 'mp4';
        final bIsAac =
            bCodec.contains('mp4a') || b.container.name.toLowerCase() == 'mp4';
        if (aIsAac != bIsAac) return aIsAac ? -1 : 1;
        final aBr = a.bitrate.bitsPerSecond;
        final bBr = b.bitrate.bitsPerSecond;
        if (aBr != bBr) return bBr.compareTo(aBr);
        final aLen = a.size.totalBytes;
        final bLen = b.size.totalBytes;
        if (aLen > 0 && bLen > 0) return bLen.compareTo(aLen);
        if (aLen > 0) return -1;
        if (bLen > 0) return 1;
        return 0;
      });
    } catch (_) {
      // Sort failed, use original order
    }
    return audio;
  }

  Future<StreamManifest> _fetchManifest(String videoId) async {
    final hit = _manifests[videoId];
    if (hit != null && DateTime.now().difference(hit.at) < _manifestTtl) {
      return hit.manifest;
    }
    // Rate limits are worth waiting out (short backoff); anything else
    // fails fast so one bad video never stalls playback for seconds.
    const waits = [Duration.zero, Duration(seconds: 2), Duration(seconds: 5)];
    Object? last;
    for (var attempt = 0; attempt < waits.length; attempt++) {
      if (attempt > 0) await Future.delayed(waits[attempt]);
      try {
        final m = await _fetchUncachedManifest(videoId);
        _manifests[videoId] = _CachedManifest(m, DateTime.now());
        if (_manifests.length > 60) {
          _manifests.remove(_manifests.keys.first);
        }
        return m;
      } catch (e) {
        last = e;
        if (!isRateLimited(e)) rethrow;
      }
    }
    throw last!;
  }

  /// Tries each client in order under a per-client and a total budget.
  /// Throws with the client chain + elapsed time so a regional report names
  /// the failing path.
  Future<StreamManifest> _fetchUncachedManifest(String videoId) async {
    final started = DateTime.now();
    final chain = _manifestClients.map(_clientName).join(' → ');
    // Cheap on the happy path (one call per app run) and decisive on
    // bot-gated IPs: without it every client answers LOGIN_REQUIRED.
    final visitorData = await _visitorDataOrNull();
    try {
      return await attemptWithBudget(
        clients: _manifestClients
            .map((c) => withVisitorData(c, visitorData))
            .toList(),
        total: _manifestBudget,
        perClient: _perClientManifestBudget,
        attempt: (client, budget) async {
          final m = await _yt.videos.streamsClient
              .getManifest(
                VideoId(videoId),
                ytClients: [client],
                requireWatchPage: false,
              )
              .timeout(budget);
          if (m.audioOnly.isEmpty) {
            throw StateError('no audio streams from ${_clientName(client)}');
          }
          return m;
        },
      );
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (text.contains('bot') || text.contains('sign in')) {
        _visitorData = null;
      }
      throw Exception(
        'no client resolved after '
        '${DateTime.now().difference(started).inMilliseconds}ms '
        '($chain); last: $e',
      );
    }
  }

  static String _clientName(YoutubeApiClient client) =>
      '${client.payload['context']?['client']?['clientName'] ?? '?'}';

  /// Per-client budget inside a shared total: one stalled client cannot eat
  /// the whole resolve. Public for the unit test only.
  @visibleForTesting
  static Future<T> attemptWithBudget<T>({
    required List<YoutubeApiClient> clients,
    required Duration total,
    required Duration perClient,
    required Future<T> Function(YoutubeApiClient client, Duration budget)
        attempt,
  }) async {
    final deadline = DateTime.now().add(total);
    Object? last;
    for (final client in clients) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final budget = remaining < perClient ? remaining : perClient;
      try {
        return await attempt(client, budget);
      } catch (e) {
        last = e;
      }
    }
    throw last ?? StateError('manifest budget exhausted');
  }

  /// VisionOS YouTube client (from the Harmony-Music fork of
  /// youtube_explode_dart). Non-Android Apple client: no androidSdkVersion,
  /// no POT requirement, and crucially NOT subject to the Android "you
  /// downloaded this stream too many times" throttle that 403s ANDROID
  /// URLs after a few ranged requests. Publicly constructible in the pinned
  /// 3.1.0 library, so we vendor the payload instead of depending on a fork.
  static const _visionosClient = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'VISIONOS',
        'clientVersion': '1.02',
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice17,1',
        'userAgent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Fallback, used only when VISIONOS stalls or is gated. Measured in the
  /// UK without `visitorData`: VISIONOS and ANDROID_VR answer
  /// "Sign in to confirm you're not a bot" (LOGIN_REQUIRED). With the token
  /// both return direct URLs. IOS was dropped: even when OK it returns no
  /// usable URL (ciphered, and there is no JS solver here).
  static const _androidVrClient = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'ANDROID_VR',
        'clientVersion': '1.65.10',
        'deviceMake': 'Oculus',
        'deviceModel': 'Quest 3',
        'androidSdkVersion': 32,
        'userAgent':
            'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
        'osName': 'Android',
        'osVersion': '12L',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Tried in order, one `getManifest` call each: passing them as a list
  /// would merge streams from clients whose media later 403s.
  static const _manifestClients = <YoutubeApiClient>[
    _visionosClient,
    _androidVrClient,
  ];

  /// Anonymous player calls from some IPs (UK/EU measured) are refused with
  /// LOGIN_REQUIRED / "Sign in to confirm you're not a bot". Supplying a
  /// visitorData token (as yt-dlp/NewPipe do) makes the same client return
  /// normal streams. Fetched once per app run; a bot-gated failure drops the
  /// cache so the next resolve gets a fresh token.
  String? _visitorData;

  Future<String?> _visitorDataOrNull() async {
    final cached = _visitorData;
    if (cached != null) return cached;
    try {
      final resp = await _http
          .post(
            Uri.parse('https://www.youtube.com/youtubei/v1/visitor_id'
                '?prettyPrint=false'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB',
                  'clientVersion': '2.20250312.04.00',
                  'hl': 'en',
                  'timeZone': 'UTC',
                  'utcOffsetMinutes': 0,
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final vd = (jsonDecode(resp.body)['responseContext']
          as Map<String, dynamic>?)?['visitorData'] as String?;
      if (vd == null || vd.isEmpty) return null;
      return _visitorData = vd;
    } catch (_) {
      // No token is better than no resolve: clients still work on IPs that
      // are not bot-gated.
      return null;
    }
  }

  /// Copies [base] with [visitorData] added to `context.client`. The const
  /// payloads stay const; the token is per-run, so it cannot live in them.
  @visibleForTesting
  static YoutubeApiClient withVisitorData(
      YoutubeApiClient base, String? visitorData) {
    if (visitorData == null) return base;
    final payload = Map<String, dynamic>.from(base.payload);
    final context = Map<String, dynamic>.from(payload['context'] as Map);
    context['client'] = {
      ...(context['client'] as Map),
      'visitorData': visitorData,
    };
    payload['context'] = context;
    return YoutubeApiClient(payload, base.apiUrl, headers: base.headers);
  }

  @override
  MediaProvider get provider => MediaProvider.youTube;

  @override
  Duration get resolveBudget => const Duration(seconds: 60);

  @override
  Future<MediaSource> resolve(Song song) async {
    final videoId = song.videoId ?? song.id;
    StreamManifest manifest;
    try {
      manifest = await _fetchManifest(videoId);
    } catch (e) {
      throw ResolveFailure(
        provider: provider,
        stage: ResolveStage.resolution,
        scope: _scopeFor(e),
        detail: 'manifest failed for $videoId: $e',
        retryable: true,
      );
    }
    final ranked = rankAudio(manifest);
    if (ranked.isEmpty) {
      throw ResolveFailure(
        provider: provider,
        stage: ResolveStage.resolution,
        scope: FailureScope.song,
        detail: 'no audio streams for $videoId',
        retryable: true,
      );
    }
    // Probe top candidates: one expired/throttled URL must not burn the
    // whole provider. First passing HEAD wins; per-URL misses are
    // url-scoped and recorded in the detail line.
    final misses = <String>[];
    var sawNetworkError = false;
    var allExpired = true;
    for (final info in ranked.take(3)) {
      // A superseded load must not keep probing URLs or fetch a fresh
      // manifest for a track nobody is waiting on.
      if (stale?.call() ?? false) {
        throw ResolveFailure(
          provider: provider,
          stage: ResolveStage.resolution,
          detail: 'resolve superseded for $videoId',
          retryable: false,
        );
      }
      final src = _toSource(info, videoId);
      try {
        await _head(src.url);
        return src;
      } on ResolveFailure catch (e) {
        if (e.scope == FailureScope.provider) sawNetworkError = true;
        if (e.scope != FailureScope.url) allExpired = false;
        misses.add('${info.tag}: ${e.detail}');
      }
    }
    // All HEAD probes got403/400: the cached manifest URLs are expired.
    // Clear the cache so the next resolve fetches fresh URLs.
    if (allExpired && misses.isNotEmpty) {
      _manifests.remove(videoId);
    }
    if (sawNetworkError) {
      throw ResolveFailure(
        provider: provider,
        stage: ResolveStage.resolution,
        scope: FailureScope.provider,
        detail: 'all candidates failed: ${misses.join('; ')}',
        retryable: true,
      );
    }
    throw ResolveFailure(
      provider: provider,
      stage: ResolveStage.resolution,
      scope: FailureScope.song,
      detail: 'all candidates rejected: ${misses.join('; ')}',
      retryable: false,
    );
  }

  @override
  Future<MediaSource> validate(MediaSource source) async {
    // resolve() already probed this exact URL seconds earlier. Re-probing
    // wastes time and can 403 a working URL. Trust the resolve probe unless
    // it's stale (>30s). Some URLs expire quickly; a fresh HEAD is cheap.
    if (DateTime.now().difference(source.resolvedAt) <
        const Duration(seconds: 30)) {
      return source;
    }
    try {
      await _head(source.url);
      return MediaSource(
        provider: source.provider,
        url: source.url,
        mimeType: source.mimeType,
        codec: source.codec,
        container: source.container,
        bitrate: source.bitrate,
        contentLength: source.contentLength,
        expiresAt: source.expiresAt,
        mediaId: source.mediaId,
        resolvedAt: DateTime.now(),
      );
    } on ResolveFailure catch (e) {
      throw ResolveFailure(
        provider: provider,
        stage: ResolveStage.validation,
        scope: _scopeFor(e),
        detail: 'validation failed for ${source.url}: ${e.detail}',
        retryable: true,
      );
    }
  }

  MediaSource _toSource(AudioOnlyStreamInfo info, String videoId) {
    final container = info.container.name.toLowerCase();
    final codec = info.codec.toString().toLowerCase();
    final bitrate = info.bitrate.bitsPerSecond;
    final clen = info.size.totalBytes;
    // Extract expiration from URL query parameters (googlevideo URLs have 'expire' param)
    DateTime? expiresAt;
    final expireParam = info.url.queryParameters['expire'];
    if (expireParam != null) {
      final secs = int.tryParse(expireParam);
      if (secs != null) {
        expiresAt =
            DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
      }
    }
    // Use the full MediaType (includes codec params) as mimeType
    final mimeType = info.codec.toString();
    return MediaSource(
      provider: provider,
      url: info.url.toString(),
      mimeType: mimeType,
      codec: codec,
      container: container,
      bitrate: bitrate,
      contentLength: clen,
      expiresAt: expiresAt,
      mediaId: videoId,
      resolvedAt: DateTime.now(),
    );
  }

  static const _headHeaders = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
    'Connection': 'keep-alive',
  };

  Future<void> _head(String url) async {
    try {
      final req = http.Request('HEAD', Uri.parse(url))
        ..headers.addAll(_headHeaders);
      final resp = await _http.send(req).timeout(const Duration(seconds: 10));
      if (resp.statusCode >= 400) {
        // 403/400 on googlevideo = expired/throttled URL, not a dead
        // provider. Mark url-scoped so it doesn't trigger cooldown.
        final scope = (resp.statusCode == 403 || resp.statusCode == 400)
            ? FailureScope.url
            : FailureScope.provider;
        throw ResolveFailure(
          provider: provider,
          stage: ResolveStage.validation,
          scope: scope,
          detail: 'HEAD ${resp.statusCode} for $url',
          retryable: true,
        );
      }
    } on ResolveFailure {
      rethrow;
    } catch (e) {
      throw ResolveFailure(
        provider: provider,
        stage: ResolveStage.validation,
        scope: FailureScope.provider,
        detail: 'HEAD failed for $url: $e',
        retryable: true,
      );
    }
  }

  @override
  Future<void> download(MediaSource source, File file) async {
    // One dead URL must not kill the download: throttle counters appear
    // per-URL (short clips download in 1 request; full songs die after a
    // few hits on the same URL). So try the passed URL, then up to 2
    // freshly-resolved alternates (different itags = different counters).
    final tried = <String>{};
    ResolveFailure? last;
    MediaSource? current = source;
    for (var attempt = 0; attempt < 3 && current != null; attempt++) {
      if (stale?.call() ?? false) {
        throw ResolveFailure(
          provider: provider,
          stage: ResolveStage.download,
          detail: 'download superseded',
          retryable: false,
        );
      }
      if (!tried.add(current.url)) break;
      try {
        await _downloadUrl(current.url, file, current.contentLength);
        return;
      } on ResolveFailure catch (e) {
        last = e;
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        // Superseded: stop immediately instead of resolving fresh alternates
        // for a track nobody is waiting on.
        if (stale?.call() ?? false) break;
        // Do not resolve a fresh candidate after the final attempt: the
        // answer would be discarded by the loop condition, so the manifest
        // fetch + URL probes are pure waste on the throttled path.
        if (attempt == 2) break;
        current = await _nextCandidate(current, tried);
      }
    }
    throw last ??
        ResolveFailure(
          provider: provider,
          stage: ResolveStage.download,
          detail: 'no downloadable URL',
          retryable: true,
        );
  }

  /// Fresh manifest, first ranked untried URL, probed. Null when
  /// nothing new is available.
  Future<MediaSource?> _nextCandidate(
      MediaSource failed, Set<String> tried) async {
    final videoId = failed.mediaId;
    if (videoId == null || videoId.isEmpty) return null;
    try {
      final manifest = await _fetchManifest(videoId);
      for (final info in rankAudio(manifest)) {
        final src = _toSource(info, videoId);
        if (tried.contains(src.url)) continue;
        try {
          await _head(src.url);
          return src;
        } catch (_) {
          tried.add(src.url);
          continue;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Chunked fetch of one URL with adaptive shrink (1MB → 64KB).
  /// Range semantics: visionos URLs return 200 (not 206) with the exact
  /// ranged body, and 416 past EOF. So completion is decided by byte
  /// accounting against [contentLength] when known, not by status code.
  Future<void> _downloadUrl(String url, File file, int? contentLength) async {
    var chunk = downloadChunkBytes;
    final baseUri = Uri.parse(url);
    final isAndroid = baseUri.queryParameters['c'] == 'ANDROID';
    final total =
        contentLength ?? int.tryParse(baseUri.queryParameters['clen'] ?? '');
    int start = 0;
    var requests = 0;
    final sink = file.openWrite();
    try {
      while (total == null || start < total) {
        // Pathological guard: a server that keeps answering with a few bytes
        // per range request must not loop forever (one 60s request each).
        // A real song needs far fewer requests than this even at the 64KB
        // floor; hitting the cap means treat it as a failed download.
        if (++requests > 4096) {
          throw ResolveFailure(
            provider: provider,
            stage: ResolveStage.download,
            detail: 'too many range requests for $url',
            retryable: true,
          );
        }
        final end = start + chunk - 1;
        final http.Request req;
        if (isAndroid) {
          req = http.Request('GET', baseUri)
            ..headers.addAll({
              'Range': 'bytes=$start-$end',
              'Connection': 'keep-alive',
            });
        } else {
          final uri = baseUri.replace(queryParameters: {
            ...baseUri.queryParameters,
            'range': '$start-$end',
          });
          req = http.Request('GET', uri)
            ..headers.addAll({'Connection': 'keep-alive'});
        }
        final resp = await _http.send(req).timeout(const Duration(seconds: 60));
        if (resp.statusCode == 416) break; // past EOF
        if (resp.statusCode == 403 || resp.statusCode == 400) {
          try {
            await resp.stream.drain();
          } catch (_) {}
          throw ResolveFailure(
            provider: provider,
            stage: ResolveStage.download,
            scope: FailureScope.provider,
            detail: 'HTTP ${resp.statusCode} for $url',
            retryable: true,
          );
        }
        if (resp.statusCode != 200 && resp.statusCode != 206) {
          try {
            await resp.stream.drain();
          } catch (_) {}
          throw ResolveFailure(
            provider: provider,
            stage: ResolveStage.download,
            scope: FailureScope.provider,
            detail: 'unexpected ${resp.statusCode} for $url',
            retryable: true,
          );
        }
        var wrote = 0;
        await for (final chunkBytes in resp.stream) {
          if (stale?.call() ?? false) {
            // Superseded mid-download: fail, don't return normally. A normal
            // return would make download() report success and let the caller
            // commit this half-written file to the cache.
            throw ResolveFailure(
              provider: provider,
              stage: ResolveStage.download,
              detail: 'download superseded for $url',
              retryable: false,
            );
          }
          sink.add(chunkBytes);
          wrote += chunkBytes.length;
          start += chunkBytes.length;
        }
        if (wrote == 0) break; // EOF
        if (total != null && start >= total) break;
        if (wrote < chunk) {
          chunk = (wrote ~/ 2).clamp(64 * 1024, downloadChunkBytes);
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    // A short read (got < chunk) ends the loop, but on flaky networks the
    // connection can drop mid-file with no error. Against a known total
    // that is truncation, not EOF: fail so download() retries a fresh
    // itag instead of caching a file that plays seconds then stops.
    // (A stale abort throws from inside the try above and never reaches here.)
    // A server that ignores the range parameter and returns the whole body
    // repeats it every iteration, so the request cap alone still allows
    // ~4 GB written to one staging file. Bound the bytes too.
    const maxStagingBytes = 256 * 1024 * 1024;
    if (start > maxStagingBytes) {
      throw ResolveFailure(
        provider: provider,
        stage: ResolveStage.download,
        detail: 'download exceeded $maxStagingBytes bytes for $url',
        retryable: true,
      );
    }
    if (total != null && start < total) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      throw ResolveFailure(
        provider: provider,
        stage: ResolveStage.download,
        detail: 'incomplete download (got $start of $total bytes)',
        retryable: true,
      );
    }
  }

  void dispose() {
    _manifests.clear();
    _http.close();
    _yt.close();
  }
}

/// Wraps a client and forces `Connection: close` on every request so no
/// dead keep-alive socket is ever reused. See the field comment in
/// [YouTubeProvider].
class _FreshConnectionClient extends http.BaseClient {
  final http.Client _inner;
  _FreshConnectionClient([http.Client? inner])
      : _inner = inner ??
            IOClient(HttpClient()
              ..connectionTimeout = const Duration(seconds: 10));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Connection'] = 'close';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// In-memory manifest entry. URLs carry their own expiry; the TTL only
/// bounds reuse so retries and replays share one InnerTube call.
class _CachedManifest {
  final StreamManifest manifest;
  final DateTime at;
  _CachedManifest(this.manifest, this.at);
}
