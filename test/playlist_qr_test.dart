import 'package:atlas_music/models/playlist.dart';
import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/playlist_qr.dart';
import 'package:flutter_test/flutter_test.dart';

Song songFor(int i, {String? title, String? artist}) => Song(
      id: 'vid${i.toString().padLeft(8, '0')}',
      title: title ?? 'Song number $i',
      artist: artist ?? 'Artist $i',
      thumbnailUrl: '',
      duration: Duration(seconds: 180 + i),
      videoId: 'vid${i.toString().padLeft(8, '0')}',
      channel: artist ?? 'Artist $i',
    );

Playlist playlistFor(List<Song> songs, {String name = 'My Playlist'}) =>
    Playlist(
      id: 'local-id',
      name: name,
      description: 'Shared from Atlas Music',
      songs: songs,
      createdAt: DateTime.now(),
      source: 'local',
    );

void main() {
  test('short playlist round-trips through a single part', () {
    final playlist = playlistFor([songFor(1), songFor(2), songFor(3)]);
    final parts = PlaylistQrCodec.encode(playlist);
    expect(parts, hasLength(1));
    expect(parts.first, startsWith('${PlaylistQrCodec.magic}:'));

    final assembler = PlaylistQrAssembler();
    expect(assembler.accept(parts.first), isTrue);
    final payload = assembler.payload!;
    expect(payload.name, 'My Playlist');
    expect(payload.description, 'Shared from Atlas Music');
    expect(payload.tracks, hasLength(3));
    expect(payload.tracks.first.videoId, 'vid00000001');
    expect(payload.tracks.first.title, 'Song number 1');
    expect(payload.tracks.first.seconds, 181);
  });

  test('long playlist splits into parts that rebuild in any order', () {
    final playlist = playlistFor([
      for (var i = 0; i < 120; i++)
        songFor(i,
            title: 'A fairly long track title about something $i',
            artist: 'Some Artist And Friends'),
    ]);
    final parts = PlaylistQrCodec.encode(playlist);
    expect(parts.length, greaterThan(1),
        reason: 'a 120 track playlist cannot fit in one QR code');
    for (final part in parts) {
      expect(part.length, lessThan(PlaylistQrCodec.maxPartLength + 32),
          reason: 'each part must stay legible as one QR code');
    }

    // Scanned out of order, as a camera naturally would.
    final assembler = PlaylistQrAssembler();
    for (final part in parts.reversed) {
      assembler.accept(part);
    }
    expect(assembler.isComplete, isTrue);
    expect(assembler.total, parts.length);
    expect(assembler.received, parts.length);
    expect(assembler.payload!.tracks, hasLength(120));
    expect(assembler.payload!.tracks.last.title,
        'A fairly long track title about something 119');
  });

  test('assembler reports progress while parts arrive', () {
    final parts = PlaylistQrCodec.encode(playlistFor([
      for (var i = 0; i < 120; i++) songFor(i),
    ]));
    expect(parts.length, greaterThan(1));
    final assembler = PlaylistQrAssembler();
    expect(assembler.accept(parts.first), isFalse);
    expect(assembler.isComplete, isFalse);
    expect(assembler.received, 1);
    expect(assembler.total, parts.length);
    expect(assembler.isMultiPart, isTrue);
  });

  test('ignores unrelated codes and stray parts from another playlist', () {
    final a = PlaylistQrCodec.encode(playlistFor(
      [for (var i = 0; i < 120; i++) songFor(i)],
      name: 'Playlist A',
    ));
    final b = PlaylistQrCodec.encode(playlistFor(
      [for (var i = 0; i < 120; i++) songFor(i)],
      name: 'Playlist B',
    ));
    expect(a.length, greaterThan(1));
    expect(b.length, greaterThan(1));
    final assembler = PlaylistQrAssembler();
    expect(assembler.accept('https://example.com'), isFalse);
    expect(assembler.accept('some random text'), isFalse);
    assembler.accept(a.first);
    // A part of a different playlist must not corrupt the one in progress.
    expect(assembler.accept(b.last), isFalse);
    for (final part in a.skip(1)) {
      assembler.accept(part);
    }
    expect(assembler.payload!.name, 'Playlist A');
  });

  test('duplicate parts do not break reassembly', () {
    final parts = PlaylistQrCodec.encode(playlistFor(
      [for (var i = 0; i < 60; i++) songFor(i)],
    ));
    final assembler = PlaylistQrAssembler();
    for (final part in [...parts, ...parts]) {
      assembler.accept(part);
    }
    expect(assembler.isComplete, isTrue);
    expect(assembler.payload!.tracks, hasLength(60));
  });

  test('consecutive encodes never share a code id', () {
    final ids = <String>{};
    for (var i = 0; i < 200; i++) {
      final parts = PlaylistQrCodec.encode(playlistFor(
        [for (var n = 0; n < 120; n++) songFor(n)],
      ));
      expect(parts.first.split(':')[1], isNotEmpty);
      ids.add(parts.first.split(':')[1]);
    }
    expect(ids, hasLength(200));
  });

  test('damaged payload throws a readable FormatException', () {
    expect(
      () => PlaylistQrCodec.decodeSingle('ATLASQR1:not-valid-gzip'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => PlaylistQrCodec.decodeSingle('https://example.com'),
      throwsA(isA<FormatException>()),
    );
    final assembler = PlaylistQrAssembler();
    expect(() => assembler.accept('ATLASQR1:abc:0:3:xyz'), throwsFormatException);
  });

  test('non-latin names and titles survive the round trip', () {
    final playlist = playlistFor(
      [
        songFor(1, title: 'तुम ही हो', artist: 'अरिजीत सिंह'),
        songFor(2, title: '夜に駆ける 🎵', artist: 'YOASOBI'),
      ],
      name: 'Bollywood & J-Pop 最高',
    );
    final parts = PlaylistQrCodec.encode(playlist);
    final assembler = PlaylistQrAssembler()..accept(parts.first);
    expect(assembler.payload!.name, 'Bollywood & J-Pop 最高');
    expect(assembler.payload!.tracks.first.title, 'तुम ही हो');
    expect(assembler.payload!.tracks.last.title, '夜に駆ける 🎵');
  });

  test('cloned playlist is independent and playable', () {
    final original = playlistFor([songFor(7)]);
    final payload = PlaylistQrPayload.fromPlaylist(original);
    final clone = payload.toPlaylist(id: 'clone-id');
    expect(clone.id, 'clone-id');
    expect(clone.name, original.name);
    expect(clone.source, PlaylistQrCodec.sourceTag);
    expect(clone.songs.single.id, 'vid00000007');
    expect(clone.songs.single.videoId, 'vid00000007');
    expect(clone.songs.single.thumbnailUrl,
        'https://i.ytimg.com/vi/vid00000007/hqdefault.jpg');
    expect(clone.songs.single.duration, const Duration(seconds: 187));
    // Local-only state must not travel with the code.
    expect(clone.isDownloaded, isFalse);
    expect(clone.downloadedSongIds, isEmpty);
    expect(clone.coverPath, isNull);
  });

  test('part size stays within one QR code of binary capacity', () {
    final parts = PlaylistQrCodec.encode(playlistFor(
      [for (var i = 0; i < 300; i++) songFor(i)],
    ));
    expect(parts.length, lessThan(PlaylistQrCodec.maxParts));
    for (final part in parts) {
      // 2953 bytes is the hard limit of QR version 40 at error correction L;
      // staying under it guarantees the renderer never has to truncate.
      expect(part.length, lessThan(2953));
    }
  });

  test('a part of another playlist first does not dead-end the import', () {
    // Force multi-part codes (>= 2) so the assembler is exercised.
    final songs = [for (var i = 0; i < 300; i++) songFor(i)];
    final payload = PlaylistQrPayload.fromPlaylist(playlistFor(songs));
    final foreign = PlaylistQrCodec.encodePayload(payload, shareId: 'other');
    final parts = PlaylistQrCodec.encodePayload(payload, shareId: 'mine');
    expect(foreign.length, greaterThan(1));
    expect(parts.length, greaterThan(1));

    final assembler = PlaylistQrAssembler();
    expect(assembler.accept(foreign.first), isFalse);
    var done = false;
    for (final part in parts) {
      done = assembler.accept(part);
    }
    expect(done, isTrue, reason: 'the real playlist must still assemble');
    expect(assembler.payload?.tracks, hasLength(songs.length));
  });
}
