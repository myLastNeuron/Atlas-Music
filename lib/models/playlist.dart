import 'song.dart';

class Playlist {
  final String id;
  final String name;
  final String? description;
  final String? thumbnailUrl;
  final String? coverPath; // local file path for a custom user-chosen image
  final List<Song> songs;
  final DateTime createdAt;
  final String? source; // 'youtube', 'spotify', 'local'
  final bool isDownloaded;
  final Set<String> downloadedSongIds;
  final bool isSystemManaged;

  Playlist({
    required this.id,
    required this.name,
    this.description,
    this.coverPath,
    this.thumbnailUrl,
    required this.songs,
    required this.createdAt,
    this.source,
    this.isDownloaded = false,
    Set<String>? downloadedSongIds,
    this.isSystemManaged = false,
  }) : downloadedSongIds = downloadedSongIds ?? {};

  factory Playlist.fromYouTube(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] ?? '',
      name: json['title'] ?? 'Untitled Playlist',
      description: json['description'],
      thumbnailUrl: json['thumbnail'],
      songs:
          (json['songs'] as List?)?.map((s) => Song.fromYouTube(s)).toList() ??
              [],
      createdAt: DateTime.now(),
      source: 'youtube',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'thumbnailUrl': thumbnailUrl,
      'coverPath': coverPath,
      'songs': songs.map((s) => s.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'source': source,
      'isDownloaded': isDownloaded,
      'downloadedSongIds': downloadedSongIds.toList(),
      'isSystemManaged': isSystemManaged,
    };
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] ?? '',
      name: json['name'] ?? 'Untitled',
      description: json['description'],
      thumbnailUrl: json['thumbnailUrl'],
      coverPath: json['coverPath'],
      songs:
          (json['songs'] as List?)?.map((s) => Song.fromJson(s)).toList() ?? [],
      createdAt:
          DateTime.parse(json['createdAt'] ?? DateTime.now().toIso8601String()),
      source: json['source'],
      isDownloaded: json['isDownloaded'] ?? false,
      downloadedSongIds:
          (json['downloadedSongIds'] as List?)?.map((e) => e as String).toSet(),
      isSystemManaged: json['isSystemManaged'] ?? false,
    );
  }

  /// Sentinel for "argument not passed": the nullable fields below can be set
  /// back to null with an explicit null, which `param ?? this.param` could not
  /// distinguish from "keep" (that made "Remove cover" a silent no-op).
  static const Object _unset = Object();

  Playlist copyWith({
    String? id,
    String? name,
    Object? description = _unset,
    Object? thumbnailUrl = _unset,
    Object? coverPath = _unset,
    List<Song>? songs,
    DateTime? createdAt,
    Object? source = _unset,
    bool? isDownloaded,
    Set<String>? downloadedSongIds,
    bool? isSystemManaged,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      description:
          identical(description, _unset) ? this.description : description as String?,
      thumbnailUrl:
          identical(thumbnailUrl, _unset) ? this.thumbnailUrl : thumbnailUrl as String?,
      coverPath: identical(coverPath, _unset) ? this.coverPath : coverPath as String?,
      songs: songs ?? this.songs,
      createdAt: createdAt ?? this.createdAt,
      source: identical(source, _unset) ? this.source : source as String?,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      downloadedSongIds: downloadedSongIds ?? this.downloadedSongIds,
      isSystemManaged: isSystemManaged ?? this.isSystemManaged,
    );
  }
}
