import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/playlist.dart';
import '../models/song.dart';

/// A playlist reduced to what a QR code can carry: the name, the optional
/// description, and every track's id/title/artist/duration. Everything else
/// (cover, offline flags, system state) is device-local and must not travel.
class PlaylistQrPayload {
  final String name;
  final String? description;
  final List<PlaylistQrTrack> tracks;

  const PlaylistQrPayload({
    required this.name,
    this.description,
    required this.tracks,
  });

  factory PlaylistQrPayload.fromPlaylist(Playlist playlist) => PlaylistQrPayload(
        name: playlist.name,
        description: playlist.description,
        tracks: [for (final s in playlist.songs) PlaylistQrTrack.fromSong(s)],
      );

  Map<String, dynamic> toJson() => {
        'n': name,
        if (description != null && description!.isNotEmpty) 'd': description,
        's': [for (final t in tracks) t.toJson()],
      };

  factory PlaylistQrPayload.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['s'];
    return PlaylistQrPayload(
      name: (json['n'] as String?)?.trim().isNotEmpty == true
          ? json['n'] as String
          : 'Imported playlist',
      description: json['d'] as String?,
      tracks: rawTracks is List
          ? [
              for (final t in rawTracks)
                if (t is List) PlaylistQrTrack.fromJson(t)
            ]
          : const [],
    );
  }

  /// Builds a fresh, independent playlist for the receiving device. The id is
  /// supplied by the caller so two imports of the same code never collide.
  Playlist toPlaylist({required String id, DateTime? createdAt}) => Playlist(
        id: id,
        name: name,
        description: description,
        songs: [for (final t in tracks) t.toSong()],
        createdAt: createdAt ?? DateTime.now(),
        source: PlaylistQrCodec.sourceTag,
      );
}

class PlaylistQrTrack {
  final String videoId;
  final String title;
  final String artist;
  final int seconds;

  const PlaylistQrTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.seconds,
  });

  factory PlaylistQrTrack.fromSong(Song song) => PlaylistQrTrack(
        videoId: (song.videoId ?? '').isNotEmpty ? song.videoId! : song.id,
        title: song.title,
        artist: song.artist,
        seconds: song.duration.inSeconds,
      );

  List<dynamic> toJson() => [videoId, title, artist, seconds];

  factory PlaylistQrTrack.fromJson(List<dynamic> json) => PlaylistQrTrack(
        videoId: '${json.isNotEmpty ? json[0] : ''}',
        title: '${json.length > 1 ? json[1] : ''}',
        artist: '${json.length > 2 ? json[2] : ''}',
        seconds: json.length > 3 && json[3] is num
            ? (json[3] as num).toInt()
            : 0,
      );

  Song toSong() => Song(
        // Keep the original id so likes/history line up when the same track
        // already exists on this device.
        id: videoId,
        title: title.isEmpty ? 'Unknown' : title,
        artist: artist.isEmpty ? 'Unknown' : artist,
        thumbnailUrl: videoId.isEmpty
            ? ''
            : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
        duration: Duration(seconds: seconds),
        videoId: videoId.isEmpty ? null : videoId,
        channel: artist,
      );
}

/// Encodes a playlist into one or more QR payload strings.
///
/// A single QR cannot hold a full playlist: the largest QR code tops out at
/// ~2.9 KB of binary data, while a 40-track playlist with titles is already
/// bigger than that once encoded. So the payload is gzipped, base64url'd, and
/// split across numbered parts that each stay small enough to scan reliably
/// from a phone screen. A short playlist produces exactly one part; a long
/// one produces N parts that carry a shared share-id, and the receiving app
/// stitches them back together in any scan order.
class PlaylistQrCodec {
  /// Format marker. Bump the version when the wire format changes.
  static const magic = 'ATLASQR1';

  /// Marks playlists that arrived through a QR code (shown on the detail
  /// screen). Not a network source.
  static const sourceTag = 'atlas_qr';

  /// Characters of encoded payload per QR image. Sized so that a code stays
  /// legible even after a chat app re-compresses the shared photo: ~900 chars
  /// lands near 100 modules, which still gives 6+ pixels per module.
  static const maxPartLength = 900;

  static const _sep = ':';

  /// Largest part count we accept when decoding. Keeps a hostile or corrupt
  /// code from making the collector allocate without bound.
  static const maxParts = 200;

  static bool looksLikePlaylistQr(String raw) =>
      raw.startsWith('$magic$_sep');

  static List<String> encode(Playlist playlist) =>
      encodePayload(PlaylistQrPayload.fromPlaylist(playlist));

  static List<String> encodePayload(PlaylistQrPayload payload,
      {String? shareId}) {
    final raw = jsonEncode(payload.toJson());
    final body = base64Url
        .encode(GZipCodec().encode(utf8.encode(raw)))
        .replaceAll('=', '');
    if (body.length <= maxPartLength) return ['$magic$_sep$body'];
    final chunks = _split(body, maxPartLength);
    final id = shareId ?? _newShareId();
    return [
      for (var i = 0; i < chunks.length; i++)
        '$magic$_sep$id$_sep${i + 1}$_sep${chunks.length}$_sep${chunks[i]}',
    ];
  }

  /// Decodes a complete single-part payload. Throws [FormatException] when
  /// [raw] is not a whole playlist code.
  static PlaylistQrPayload decodeSingle(String raw) {
    if (!raw.startsWith('$magic$_sep')) {
      throw const FormatException('Not an Atlas Music playlist code');
    }
    final body = raw.substring(magic.length + 1);
    if (body.contains(_sep)) {
      throw const FormatException('This code is only part of a playlist');
    }
    return _decodeBody(body);
  }

  static PlaylistQrPayload _decodeBody(String body) {
    try {
      final bytes = base64Url.decode(base64Url.normalize(body));
      final json = jsonDecode(utf8.decode(GZipCodec().decode(bytes)));
      if (json is! Map) throw const FormatException('Bad playlist payload');
      return PlaylistQrPayload.fromJson(json.cast<String, dynamic>());
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('This QR code is damaged or unreadable');
    }
  }

  static List<String> _split(String text, int size) {
    final out = <String>[];
    for (var i = 0; i < text.length; i += size) {
      out.add(text.substring(i, i + size > text.length ? text.length : i + size));
    }
    return out;
  }

  /// Short, URL-safe share id so parts of different playlists never mix.
  /// Time alone is not enough: two encodes in the same microsecond would get
  /// the same id (random is seeded from the clock too), so a counter is mixed
  /// in as well.
  static int _shareSequence = 0;

  static String _newShareId() {
    final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final seq = (_shareSequence++ & 0xFFFFF).toRadixString(36);
    final rand = Random().nextInt(1 << 20).toRadixString(36);
    final raw = '$micros$seq$rand';
    return raw.substring(raw.length - 8);
  }
}

/// Collects the parts of one playlist code, in any order, from repeated
/// scans. Also accepts a single-part code, which completes immediately.
class PlaylistQrAssembler {
  String? _shareId;
  int _total = 1;
  final Map<int, String> _parts = {};
  PlaylistQrPayload? _payload;

  int get total => _total;

  int get received => _payload != null ? _total : _parts.length;

  bool get isComplete => _payload != null;

  bool get isMultiPart => _total > 1;

  PlaylistQrPayload? get payload => _payload;

  void reset() {
    _shareId = null;
    _total = 1;
    _parts.clear();
    _payload = null;
  }

  /// Feeds one scanned value. Returns true once a whole playlist is available.
  /// Values that are not playlist codes are ignored; a code from a different
  /// playlist (a stray part) is ignored too. Throws [FormatException] only
  /// when a playlist code is present but malformed or damaged.
  bool accept(String raw) {
    if (isComplete) return true;
    final value = raw.trim();
    if (!PlaylistQrCodec.looksLikePlaylistQr(value)) return false;
    final fields = value.split(':');
    if (fields.length == 2) {
      _payload = PlaylistQrCodec.decodeSingle(value);
      _total = 1;
      return true;
    }
    if (fields.length != 5) {
      throw const FormatException('This QR code is not a valid playlist');
    }
    final id = fields[1];
    final index = int.tryParse(fields[2]);
    final total = int.tryParse(fields[3]);
    if (index == null ||
        total == null ||
        total < 1 ||
        total > PlaylistQrCodec.maxParts ||
        index < 1 ||
        index > total) {
      throw const FormatException('This QR code is damaged');
    }
    if (_shareId != null && _shareId != id) {
      // Parts of another playlist are ignored, but a part 1 always starts a
      // fresh assembly: latching onto a stray first part of a different
      // playlist used to dead-end the import with no error and no reset.
      if (index != 1) return false;
      _parts.clear();
      _total = 1;
    }
    if (_parts.isNotEmpty && total != _total) return false;
    _shareId = id;
    _total = total;
    _parts[index] = fields[4];
    if (_parts.length < total) return false;
    final body = [
      for (var i = 1; i <= total; i++)
        if (_parts[i] == null)
          throw const FormatException('A part of this playlist is missing')
        else
          _parts[i]!
    ].join();
    _payload = PlaylistQrCodec._decodeBody(body);
    return true;
  }
}
