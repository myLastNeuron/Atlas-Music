import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/media/media_source.dart';
import 'package:atlas_music/media/providers/youtube_provider.dart';
import 'package:atlas_music/media/resolve_failure.dart';

/// F2/F16 regression: the stale hook must actually abort a superseded
/// download (it was hard-wired to `() => false`), and an abort must surface
/// as a non-retryable cancel rather than a "corrupt download" retry.
void main() {
  MediaSource src() => MediaSource(
        provider: MediaProvider.youTube,
        url: 'https://example.invalid/audio',
        mimeType: 'audio/mp4',
        codec: 'mp4a.40.2',
        container: 'mp4',
        contentLength: 1024,
        resolvedAt: DateTime.now(),
      );

  test('download aborts before network work when stale', () async {
    final provider = YouTubeProvider(stale: () => true);
    final tmp = File(
        '${Directory.systemTemp.path}/atlas_stale_${DateTime.now().microsecondsSinceEpoch}.part');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync();
      provider.dispose();
    });

    await expectLater(
      provider.download(src(), tmp),
      throwsA(isA<ResolveFailure>().having(
        (e) => e.retryable,
        'retryable',
        false,
      )),
    );
    expect(tmp.existsSync(), isFalse,
        reason: 'no bytes should be written for an aborted download');
  });
}
