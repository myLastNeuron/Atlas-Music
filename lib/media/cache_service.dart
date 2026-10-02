import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import 'media_source.dart';

/// Dedicated audio cache. Rules:
/// - Deterministic key: `atlas2_{sanitized song id}.{ext}` (+ `.json` sidecar).
///   v2 namespace: pre-v2 cache may hold truncated downloads (short reads
///   once committed as EOF), so old `atlas_` entries are never reused.
/// - Sidecar metadata: song id/title, provider, source URL, byte count,
///   download timestamp. Used for TTL + corruption checks.
/// - TTL 14 days; total size cap 1GB with oldest-first eviction.
/// - Corruption detection: zero-byte files rejected; when the source knew
///   its content length, committed size must match exactly.
/// - Cached replays never touch the network (offline-first).
/// - Sweep on service init is best-effort only; never evict files currently
///   in active playback queue.
class CacheService {
  static const ttl = Duration(days: 7);
  static const maxBytes = 1 * 1024 * 1024 * 1024;

  final Directory? baseDirOverride;
  Directory? _baseDir;
  Future<Directory>? _baseDirFuture;

  /// Approximate cached byte total, maintained across commits so a normal
  /// download does not trigger a full directory scan + N stats. Invalidated
  /// (set null) whenever it cannot be trusted; then enforceCap rescans.
  int? _approxBytes;

  CacheService({Directory? baseDir}) : baseDirOverride = baseDir;

  /// Resolves the cache root once and caches it. Default is the app's
  /// persistent files directory (getApplicationDocumentsDirectory): the
  /// OS-evictable temp/cache dir (Directory.systemTemp on Android) can be
  /// cleared under storage pressure, silently deleting preloaded files and
  /// forcing a full re-download at the next-track advance. A caller-supplied
  /// [baseDir] (tests) always wins.
  Future<Directory> _resolveBaseDir() {
    final cached = _baseDirFuture;
    if (cached != null) return cached;
    final f = _resolveBaseDirInner();
    _baseDirFuture = f;
    return f;
  }

  Future<Directory> _resolveBaseDirInner() async {
    final o = baseDirOverride;
    if (o != null) {
      _baseDir = o;
      return o;
    }
    try {
      final d = await getApplicationDocumentsDirectory();
      _baseDir = d;
      return d;
    } catch (_) {
      _baseDir = Directory.systemTemp;
      return Directory.systemTemp;
    }
  }

  /// Synchronous view for callers that build paths before the async root
  /// is resolved (stageFile). Always points at the override or the last
  /// resolved default; commit re-resolves so final writes land in the
  /// persistent dir.
  Directory get _currentDir =>
      _baseDir ?? baseDirOverride ?? Directory.systemTemp;

  static String safeId(String id) =>
      id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  /// Smallest plausible byte count for a real audio download. Scaled by the
  /// song's known duration at a ~24 kbps floor; unknown length falls back to
  /// a small absolute floor that still rejects error pages and empty bodies.
  /// A 15s preview of a full song stays well under its expected floor.
  static const int _absoluteMinBytes = 16 * 1024;
  static int _minBytesFor(Song song) {
    final sec = song.duration.inSeconds;
    if (sec <= 0) return _absoluteMinBytes;
    final byDuration = sec * 3000;
    return byDuration > _absoluteMinBytes ? byDuration : _absoluteMinBytes;
  }

  String keyFor(Song song) {
    final id = safeId(song.videoId ?? song.id);
    return 'atlas2_$id';
  }

  /// ALL keys a song may live under. The write key prefers videoId, but
  /// queue instances rebuilt from storage/search can carry a different
  /// id/videoId pairing for the same track — reads must try every key,
  /// or a downloaded file becomes invisible and the advance wrongly
  /// gates offline_no_cache (the phantom 2->1 wrap).
  List<String> keysFor(Song song) {
    final keys = <String>[keyFor(song)];
    final idKey = 'atlas2_${safeId(song.id)}';
    if (!keys.contains(idKey)) keys.add(idKey);
    return keys;
  }

  File fileFor(Song song, {String ext = 'm4a'}) =>
      File('${_currentDir.path}/${keyFor(song)}.$ext');

  File sidecarFor(Song song, {String ext = 'm4a'}) =>
      File('${_currentDir.path}/${keyFor(song)}.$ext.json');

  /// Valid cached file, or null. Never throws. Tries every key the song
  /// may live under (see [keysFor]) and any known audio extension.
  Future<File?> getValid(Song song) async {
    try {
      final dir = await _resolveBaseDir();
      File? file;
      for (final key in keysFor(song)) {
        for (final ext in ['m4a', 'mp3', 'webm']) {
          final f = File('${dir.path}/$key.$ext');
          if (await f.exists()) {
            file = f;
            break;
          }
        }
        if (file != null) break;
      }
      if (file == null) return null;
      if (await file.length() == 0) {
        await _deleteQuiet(file);
        return null;
      }
      final meta = await _readSidecar(song, file);
      if (meta == null) {
        // No sidecar: legacy file from before byte-count validation.
        // Those builds committed short reads as EOF (17s truncated audio).
        // Force fresh download instead of replaying the snippet.
        await _deleteQuiet(file);
        return null;
      }
      {
        final at = DateTime.tryParse(meta['downloadedAt'] as String? ?? '');
        if (at != null && DateTime.now().difference(at) > ttl) {
          await _deleteQuiet(file);
          await _deleteQuiet(File('${file.path}.json'));
          return null;
        }
        final expected = meta['bytes'] as int?;
        if (expected != null &&
            expected > 0 &&
            await file.length() != expected) {
          await _deleteQuiet(file); // corrupted / partial
          return null;
        }
      }
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Validate [tmp] (downloaded via resolver) and promote it into the
  /// cache under the deterministic key. Returns the cache file.
  /// Throws [StateError] on corruption (caller records it and moves on).
  /// Commits a download, then enforces the size cap WITHOUT evicting
  /// [keepKeys] (key prefixes like `atlas2_<id>` for songs in the active
  /// playback queue). Without this, a commit during playback could evict
  /// an upcoming queued song, which then gates offline_no_cache at
  /// advance time despite having been downloaded.
  Future<File> commit(Song song, File tmp, MediaSource source,
      {Set<String>? keepKeys}) async {
    final ext = _extFor(source);
    final dir = await _resolveBaseDir();
    final dest = File('${dir.path}/${keyFor(song)}.$ext');
    final bytes = await tmp.length();
    if (bytes <= 0) {
      await _deleteQuiet(tmp);
      throw StateError('empty download');
    }
    // Reject implausibly small files: a truncated body, a throttled error
    // page, or a preview clip that would play a few seconds and stop. The
    // floor scales with the known song length (~24 kbps minimum) so
    // legitimate short/low-bitrate tracks (e.g. a 1-minute opus song) are
    // not thrown away, while fixed-size error pages still fail.
    final minBytes = _minBytesFor(song);
    if (bytes < minBytes) {
      await _deleteQuiet(tmp);
      throw StateError(
          'download too small ($bytes bytes, expected ≥$minBytes)');
    }
    if (source.contentLength != null &&
        source.contentLength! > 0 &&
        bytes != source.contentLength) {
      await _deleteQuiet(tmp);
      throw StateError(
          'size mismatch (got $bytes, expected ${source.contentLength})');
    }
    if (await dest.exists()) await dest.delete();
    await tmp.rename(dest.path);
    await sidecarFor(song, ext: ext).writeAsString(json.encode({
      'songId': song.videoId ?? song.id,
      'title': song.title,
      'provider': source.provider.name,
      'url': source.url,
      'bytes': bytes,
      'downloadedAt': DateTime.now().toIso8601String(),
    }));
    if (_approxBytes != null) _approxBytes = _approxBytes! + bytes;
    await enforceCap(keepKeys: keepKeys);
    return dest;
  }

  /// Staging file for a fresh download (outside the key namespace so a
  /// crash never leaves a half-valid cache entry behind).
  Future<File> stageFile(Song song) async {
    // Resolve the persistent root so the staging download and the final
    // commit land in the SAME directory (no cross-directory rename, which
    // can fail across filesystems and silently drop the cache).
    final dir = await _resolveBaseDir();
    return File(
        '${dir.path}/${keyFor(song)}.${DateTime.now().microsecondsSinceEpoch}.part');
  }

  Future<void> invalidate(Song song) async {
    final dir = await _resolveBaseDir();
    for (final key in keysFor(song)) {
      for (final ext in ['m4a', 'mp3', 'webm']) {
        await _deleteQuiet(File('${dir.path}/$key.$ext'));
        await _deleteQuiet(File('${dir.path}/$key.$ext.json'));
      }
    }
    _approxBytes = null;
  }

  /// TTL sweep + orphan `.part` cleanup + size-cap eviction.
  Future<void> sweep() async {
    _approxBytes = null;
    try {
      final dir = await _resolveBaseDir();
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('atlas_') && !name.startsWith('atlas2_')) continue;
        if (name.endsWith('.part')) {
          await _deleteQuiet(e);
          continue;
        }
        if (name.endsWith('.json')) continue;
        final stat = await e.stat();
        if (DateTime.now().difference(stat.modified) > ttl) {
          await _deleteQuiet(e);
          await _deleteQuiet(File('${e.path}.json'));
          continue;
        }
        // v1 namespace retired (may hold truncated downloads): evict.
        if (name.startsWith('atlas_') && !name.startsWith('atlas2_')) {
          await _deleteQuiet(e);
          await _deleteQuiet(File('${e.path}.json'));
        }
      }
      await enforceCap();
    } catch (_) {}
  }

  Future<void> enforceCap({Set<String>? keepKeys}) async {
    try {
      final dir = await _resolveBaseDir();
      // Fast path: the approximate total is trusted and well below the cap,
      // so a full scan would be pure waste on every one of N playlist
      // downloads. A 10% margin absorbs sidecar drift.
      if (_approxBytes != null &&
          _approxBytes! < (maxBytes * 0.9).round() &&
          keepKeys == null) {
        return;
      }
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if ((name.startsWith('atlas_') || name.startsWith('atlas2_')) &&
            !name.endsWith('.json') &&
            !name.endsWith('.part')) {
          files.add(e);
        }
      }
      final sizes = <File, int>{};
      var total = 0;
      for (final f in files) {
        final st = await f.stat();
        sizes[f] = st.size;
        total += st.size;
      }
      _approxBytes = total;
      if (total <= maxBytes) return;
      // Oldest-first eviction. Use the stat we already paid for instead of
      // two more synchronous statSync() calls per comparison.
      final modified = <File, DateTime>{};
      for (final f in files) {
        modified[f] = (await f.stat()).modified;
      }
      files.sort((a, b) => modified[a]!.compareTo(modified[b]!));
      for (final f in files) {
        if (total <= maxBytes) break;
        if (keepKeys != null) {
          final name = f.path.split(Platform.pathSeparator).last;
          if (keepKeys.any(name.startsWith)) continue;
        }
        total -= sizes[f]!;
        _approxBytes = total;
        await _deleteQuiet(f);
        await _deleteQuiet(File('${f.path}.json'));
      }
    } catch (_) {
      _approxBytes = null;
    }
  }

  Future<Map<String, dynamic>?> _readSidecar(Song song, File file) async {
    try {
      // Sidecar sits next to the file itself: the file may live under an
      // alternate key (see [keysFor]), so never re-derive from the song.
      final raw = await File('${file.path}.json').readAsString();
      return json.decode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  String _extFor(MediaSource source) {
    final c = (source.container ?? '').toLowerCase();
    if (c.contains('mp3')) return 'mp3';
    if (c.contains('webm')) return 'webm';
    final m = (source.mimeType ?? '').toLowerCase();
    if (m.contains('mpeg')) return 'mp3';
    if (m.contains('webm')) return 'webm';
    return 'm4a';
  }

  Future<void> _deleteQuiet(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
