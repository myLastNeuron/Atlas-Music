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

  test('terms stay unaccepted until accepted, then never prompt again',
      () async {
    final prefs = UserPrefs();
    expect(await prefs.hasAcceptedTerms(), isFalse);
    await prefs.acceptTerms();
    expect(await prefs.hasAcceptedTerms(), isTrue);
  });

  test('the Song/Video choice is a saved preference', () async {
    // Video is a choice, not a per-song state: it has to survive the mini
    // player, a restart and every following track.
    final prefs = UserPrefs();
    expect(await prefs.getVideoMode(), isFalse);
    await prefs.setVideoMode(true);
    expect(await UserPrefs().getVideoMode(), isTrue);
    await prefs.setVideoMode(false);
    expect(await UserPrefs().getVideoMode(), isFalse);
  });
}
