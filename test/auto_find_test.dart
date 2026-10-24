import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:atlas_music/models/song.dart';
import 'package:atlas_music/services/storage_service.dart';

Song _song(String id, String title) => Song(
      id: id,
      title: title,
      artist: 'A',
      thumbnailUrl: '',
      duration: Duration.zero,
      videoId: 'v$id',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('auto finds stay newest-first, timestamped, and are removable',
      () async {
    final storage = StorageService.instance;
    await storage.clearAutoFinds();

    await storage.addAutoFind(_song('a', 'A'));
    await storage.addAutoFind(_song('a', 'A')); // consecutive repeat collapses
    await storage.addAutoFind(_song('b', 'B'));

    final finds = await storage.getAutoFinds();
    expect(finds.map((f) => f.song.id).toList(), ['b', 'a']);
    expect(
      finds.first.foundAt
          .isAfter(DateTime.now().subtract(const Duration(minutes: 1))),
      isTrue,
    );

    await storage.removeAutoFind(finds.first);
    expect((await storage.getAutoFinds()).map((f) => f.song.id).toList(), ['a']);

    // Removal targets the entry itself, not a list position: a stale target
    // must not delete whatever happens to sit at that index now.
    await storage.addAutoFind(_song('c', 'C'));
    await storage.removeAutoFind(finds.first); // 'b', already gone
    expect((await storage.getAutoFinds()).map((f) => f.song.id).toList(),
        ['c', 'a']);

    await storage.clearAutoFinds();
    expect(await storage.getAutoFinds(), isEmpty);
  });
}
