import 'package:atlas_music/models/playlist.dart';
import 'package:flutter_test/flutter_test.dart';

// Regression: copyWith used `param ?? this.param`, so a nullable field could
// never be cleared ("Remove cover" was a silent no-op).
void main() {
  Playlist base() => Playlist(
        id: 'p',
        createdAt: DateTime(2024, 1, 1),
        name: 'Mix',
        description: 'desc',
        thumbnailUrl: 'https://example.test/t.jpg',
        coverPath: '/tmp/cover.jpg',
        source: 'qr',
        songs: [],
      );

  test('an explicit null clears a nullable field', () {
    final cleared = base().copyWith(coverPath: null, description: null);
    expect(cleared.coverPath, isNull);
    expect(cleared.description, isNull);
    expect(cleared.name, 'Mix', reason: 'omitted fields keep their value');
  });

  test('omitting a nullable field keeps it', () {
    final same = base().copyWith(name: 'Renamed');
    expect(same.coverPath, '/tmp/cover.jpg');
    expect(same.thumbnailUrl, 'https://example.test/t.jpg');
    expect(same.source, 'qr');
    expect(same.name, 'Renamed');
  });
}
