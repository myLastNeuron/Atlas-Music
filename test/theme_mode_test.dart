import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:atlas_music/services/theme_settings.dart';
import 'package:atlas_music/theme/app_theme.dart';

/// The palette is global state, so these tests must not leak a mode into each
/// other: every one sets the mode it needs and restores grey at the end.
void main() {
  // The palette swap also sets the status bar style, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => AppColors.mode = AppPalette.grey);

  test('each mode swaps the paper and ink, AMOLED is pure black', () {
    AppColors.mode = AppPalette.grey;
    final greyPaper = AppColors.paper;
    final greyInk = AppColors.ink;

    AppColors.mode = AppPalette.light;
    expect(AppColors.isLight, isTrue);
    expect(AppColors.paper, isNot(greyPaper));
    expect(AppColors.ink, isNot(greyInk));
    // Ink must stay legible: dark text on the light paper.
    expect(AppColors.paper.computeLuminance(),
        greaterThan(AppColors.ink.computeLuminance()));

    AppColors.mode = AppPalette.amoled;
    expect(AppColors.isAmoled, isTrue);
    expect(AppColors.isLight, isFalse);
    expect(AppColors.paper, const Color(0xFF000000));
    expect(AppColors.ink, const Color(0xFFFFFFFF));
  });

  test('the mode is stored and read back before the first frame', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = ThemeSettings();
    await settings.setMode(AppPalette.amoled);
    expect(settings.mode, AppPalette.amoled);

    // A fresh instance (the next launch) reads the stored mode.
    final next = ThemeSettings();
    await next.load();
    expect(next.mode, AppPalette.amoled);
    expect(AppColors.isAmoled, isTrue);
  });

  test('a light-only install migrates to the light palette', () async {
    SharedPreferences.setMockInitialValues({'theme_light': true});
    final settings = ThemeSettings();
    await settings.load();
    expect(settings.mode, AppPalette.light);
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
    // It must not drag the appearance mode with it.
    expect(next.mode, AppPalette.grey);
  });
}
