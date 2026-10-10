import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:atlas_music/services/user_prefs.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('artist names containing a comma round-trip intact', () async {
    final prefs = UserPrefs();
    await prefs.setArtists({'Tyler, The Creator', 'Ed Sheeran'});
    expect(await prefs.getArtists(), {'Tyler, The Creator', 'Ed Sheeran'});
    await prefs.setGenres({'Hip Hop / Rap', 'R&B / Soul'});
    expect(await prefs.getGenres(), {'Hip Hop / Rap', 'R&B / Soul'});
  });

  test('legacy comma-joined value is still readable', () async {
    SharedPreferences.setMockInitialValues({'music_artists': 'A,B'});
    expect(await UserPrefs().getArtists(), {'A', 'B'});
  });
}
