import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/media/cache_service.dart';
import 'package:atlas_music/media/media_source.dart';
import 'package:atlas_music/models/song.dart';

Song get song => Song(
      id: 'vid:123',
      title: 'T',
      artist: 'A',
      thumbnailUrl: '',
      duration: const Duration(seconds: 200),
      videoId: 'vid:123',
    );

/// A byte body large enough to pass the duration-scaled minimum size
/// (200s × ~3 KB/s floor ≈ 600 KB).
List<int> realisticBytes() => List<int>.filled(800 * 1024, 0);

MediaSource src({int? len}) => MediaSource(
      provider: MediaProvider.youTube,
      url: 'https://x/y',
      mimeType: 'audio/mp4',
      codec: 'mp4a.40.2',
      container: 'mp4',
      contentLength: len,
      resolvedAt: DateTime.now(),
    );

void main() {
  late Directory dir;
  late CacheService cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('atlas_test_');
    cache = CacheService(baseDir: dir);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('key is deterministic and filesystem-safe', () {
    expect(CacheService.safeId('a/b:c?d'), 'a_b_c_d');
    expect(cache.keyFor(song), 'atlas2_vid_123');
  });

  test('commit then replay without network', () async {
    final bytes = realisticBytes();
    final tmp = File('${dir.path}/up.part')..writeAsBytesSync(bytes);
    final file = await cache.commit(song, tmp, src(len: bytes.length));
    expect(await file.exists(), isTrue);
    final hit = await cache.getValid(song);
    expect(hit?.path, file.path);
  });

  test('implausibly small download rejected', () async {
    final tmp = File('${dir.path}/tiny.part')
      ..writeAsBytesSync(List<int>.filled(100, 120));
    expect(() => cache.commit(song, tmp, src(len: 100)), throwsStateError);
  });

  test('zero-byte download rejected', () async {
    final tmp = File('${dir.path}/empty.part')..writeAsStringSync('');
    expect(() => cache.commit(song, tmp, src()), throwsStateError);
    expect(await cache.getValid(song), isNull);
  });

  test('size mismatch rejected as corruption', () async {
    final tmp = File('${dir.path}/short.part')
      ..writeAsBytesSync(realisticBytes());
    expect(() => cache.commit(song, tmp, src(len: 999)), throwsStateError);
    expect(await cache.getValid(song), isNull);
  });

  test('sweep keeps a valid cached entry under the size cap', () async {
    final small = CacheService(baseDir: dir);
    // Eviction ordering is not testable here: maxBytes is a static const,
    // so the cap cannot be shrunk. This asserts the complementary property
    // (a valid entry survives sweep) — see CacheService docs for eviction.
    final bytes = realisticBytes();
    final tmp = File('${dir.path}/a.part')..writeAsBytesSync(bytes);
    await small.commit(song, tmp, src(len: bytes.length));
    await small.sweep();
    expect(await small.getValid(song), isNotNull);
  });

  test('re-download as another container removes the stale variant', () async {
    final bytes = realisticBytes();
    final first = File('${dir.path}/a.part')..writeAsBytesSync(bytes);
    await cache.commit(song, first, src(len: bytes.length)); // m4a
    final m4a = File('${dir.path}/${cache.keyFor(song)}.m4a');
    expect(await m4a.exists(), isTrue);

    final second = File('${dir.path}/b.part')..writeAsBytesSync(bytes);
    final webmSrc = MediaSource(
      provider: MediaProvider.youTube,
      url: 'https://x/w',
      mimeType: 'audio/webm',
      codec: 'opus',
      container: 'webm',
      contentLength: bytes.length,
      resolvedAt: DateTime.now(),
    );
    final committed = await cache.commit(song, second, webmSrc);
    expect(committed.path, endsWith('.webm'));
    expect(await m4a.exists(), isFalse, reason: 'stale m4a must be gone');
    expect((await cache.getValid(song))?.path, committed.path);
  });

  test('30-day TTL sweep keeps explicit downloads, drops streamed cache',
      () async {
    final downloaded = Song(
      id: 'dl',
      title: 'D',
      artist: 'A',
      thumbnailUrl: '',
      duration: const Duration(seconds: 200),
      videoId: 'dl',
    );
    for (final (i, s) in [song, downloaded].indexed) {
      final bytes = realisticBytes();
      final tmp = File('${dir.path}/ttl_$i.part')..writeAsBytesSync(bytes);
      await cache.commit(s, tmp, src(len: bytes.length));
    }
    await cache.markPinned(downloaded);

    final old = DateTime.now().subtract(const Duration(days: 31));
    for (final s in [song, downloaded]) {
      final f = File('${dir.path}/${cache.keyFor(s)}.m4a');
      f.setLastModifiedSync(old);
      File('${f.path}.json').setLastModifiedSync(old);
    }

    await cache.sweep();

    expect(await cache.getValid(song), isNull,
        reason: 'expired streamed cache must be swept');
    expect(await cache.getValid(downloaded), isNotNull,
        reason: 'explicit download must survive the TTL');
  });

  test('sweep pins existing downloads passed as pinKeys before TTL', () async {
    // Simulates upgrading: the file predates the pin marker but is in the
    // user's download list, so boot-time sweep must protect it.
    final bytes = realisticBytes();
    final tmp = File('${dir.path}/old_dl.part')..writeAsBytesSync(bytes);
    await cache.commit(song, tmp, src(len: bytes.length));
    final f = File('${dir.path}/${cache.keyFor(song)}.m4a');
    final old = DateTime.now().subtract(const Duration(days: 40));
    f.setLastModifiedSync(old);
    File('${f.path}.json').setLastModifiedSync(old);

    await cache.sweep(pinKeys: cache.keysFor(song).toSet());

    expect(await cache.getValid(song), isNotNull,
        reason: 'migrated download must survive the sweep');
  });

  test('re-commit keeps an existing pin', () async {
    final bytes = realisticBytes();
    final first = File('${dir.path}/pin1.part')..writeAsBytesSync(bytes);
    await cache.commit(song, first, src(len: bytes.length), pinned: true);

    // Playback re-fetches after a corruption hit: no pinned flag passed.
    final second = File('${dir.path}/pin2.part')..writeAsBytesSync(bytes);
    final file = await cache.commit(song, second, src(len: bytes.length));

    final meta = jsonDecode(await File('${file.path}.json').readAsString())
        as Map<String, dynamic>;
    expect(meta['pinned'], isTrue);

    file.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 40)));
    await cache.sweep();
    expect(await cache.getValid(song), isNotNull);
  });

  test('commit with pinned survives cap enforcement at commit time', () async {
    final bytes = realisticBytes();
    final tmp = File('${dir.path}/pin_at_commit.part')
      ..writeAsBytesSync(bytes);
    final file =
        await cache.commit(song, tmp, src(len: bytes.length), pinned: true);
    final meta = jsonDecode(await File('${file.path}.json').readAsString())
        as Map<String, dynamic>;
    expect(meta['pinned'], isTrue,
        reason: 'pin must be written before enforceCap runs');
  });

  test('clearAll removes streamed songs but keeps downloads', () async {
    final keep = Song(
      id: 'keep',
      title: 'K',
      artist: 'A',
      thumbnailUrl: '',
      duration: const Duration(seconds: 200),
      videoId: 'keep',
    );
    for (final (i, s) in [song, keep].indexed) {
      final bytes = realisticBytes();
      final tmp = File('${dir.path}/clear_$i.part')
        ..writeAsBytesSync(bytes);
      await cache.commit(s, tmp, src(len: bytes.length));
    }
    expect(await cache.getValid(song), isNotNull);
    expect(await cache.getValid(keep), isNotNull);

    await cache.clearAll(keepSongs: [keep]);

    expect(await cache.getValid(song), isNull,
        reason: 'streamed song should be cleared');
    expect(await cache.getValid(keep), isNotNull,
        reason: 'downloaded song must survive');
  });
}
