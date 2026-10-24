import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:atlas_music/services/theme_settings.dart';
import 'package:atlas_music/theme/app_theme.dart';

/// The palette is global state, so these tests must not leak a mode into each
/// other: every one sets the mode it needs and restores dark at the end.
void main() {
  // The palette swap also sets the status bar style, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => AppColors.setLight(false));

  test('dark is the default and light flips the ink and the paper', () {
    AppColors.setLight(false);
    final darkPaper = AppColors.paper;
    final darkInk = AppColors.ink;

    AppColors.setLight(true);
    expect(AppColors.isLight, isTrue);
    expect(AppColors.paper, isNot(darkPaper));
    expect(AppColors.ink, isNot(darkInk));
    // Ink must stay legible: dark text on the light paper, and the reverse.
    expect(AppColors.paper.computeLuminance(),
        greaterThan(AppColors.ink.computeLuminance()));
  });

  test('the mode is stored and read back before the first frame', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = ThemeSettings();
    await settings.setLight(true);
    expect(settings.isLight, isTrue);

    // A fresh instance (the next launch) reads the stored mode.
    final next = ThemeSettings();
    await next.load();
    expect(next.isLight, isTrue);
    expect(AppColors.isLight, isTrue);
  });

  test('the artwork colour option is stored too', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = ThemeSettings();
    await settings.setArtworkColor(true);
    expect(settings.artworkColor, isTrue);

    final next = ThemeSettings();
    await next.load();
    expect(next.artworkColor, isTrue);
    // It must not drag the light mode with it.
    expect(next.isLight, isFalse);
  });
}
