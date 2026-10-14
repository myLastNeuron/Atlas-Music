import 'song.dart';

/// A song Auto-listen identified, and the moment it was heard.
class AutoFind {
  final Song song;
  final DateTime foundAt;

  const AutoFind({required this.song, required this.foundAt});

  Map<String, dynamic> toJson() => {
        'song': song.toJson(),
        'foundAt': foundAt.toIso8601String(),
      };

  factory AutoFind.fromJson(Map<String, dynamic> json) => AutoFind(
        song: Song.fromJson(Map<String, dynamic>.from(json['song'] as Map)),
        foundAt:
            DateTime.tryParse((json['foundAt'] ?? '') as String) ?? DateTime.now(),
      );
}
