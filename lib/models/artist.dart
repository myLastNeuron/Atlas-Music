import 'song.dart';

/// A transient view of a YouTube Music artist page. Not persisted: it is
/// rebuilt on every open from the InnerTube browse response, so it never
/// touches storage or the [Song] JSON schema.
class ArtistPage {
  final String name;
  final String? imageUrl;
  final List<Song> songs;
  final List<AlbumRef> albums;
  /// Browse id of the artist's full song list (the "Songs" shelf's "More").
  final String? songsBrowseId;

  const ArtistPage({
    required this.name,
    this.imageUrl,
    this.songs = const [],
    this.albums = const [],
    this.songsBrowseId,
  });

  bool get isEmpty => songs.isEmpty && albums.isEmpty;
}

/// A pointer to one of an artist's releases (album / single / EP). Tapping it
/// browses [browseId] for the track list; nothing here is downloaded or saved.
class AlbumRef {
  final String title;
  final String? year;
  final String browseId;
  final String? thumbnailUrl;

  const AlbumRef({
    required this.title,
    this.year,
    required this.browseId,
    this.thumbnailUrl,
  });
}
