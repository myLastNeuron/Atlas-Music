import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';

/// Appearance: light, the grey glass look, or AMOLED black, and whether the
/// full player takes its colour from the artwork. The mode swaps [AppColors]
/// and the app rebuilds from the root, which is the only way the palette can
/// reach widgets that read the colours themselves; the artwork colour is read
/// by the player alone.
class ThemeSettings extends ChangeNotifier {
  static const _key = 'theme_mode';
  static const _legacyLightKey = 'theme_light';
  static const _artKey = 'player_artwork_color';

  AppPalette _mode = AppPalette.grey;
  bool _artworkColor = false;

  AppPalette get mode => _mode;

  /// The full player tints itself with the current artwork's dominant colour
  /// instead of the app palette. Off by default; nothing else is affected.
  bool get artworkColor => _artworkColor;

  /// Reads the stored mode before the first frame, so the app never starts in
  /// the wrong palette and then flips. Installs from before the three-mode
  /// slider stored a `theme_light` bool; that is honoured once.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    _mode = stored != null
        ? AppPalette.values.firstWhere(
            (m) => m.name == stored,
            orElse: () => AppPalette.grey,
          )
        : (prefs.getBool(_legacyLightKey) ?? false)
            ? AppPalette.light
            : AppPalette.grey;
    _artworkColor = prefs.getBool(_artKey) ?? false;
    AppColors.mode = _mode;
    applySystemUiOverlay();
  }

  /// Turns the artwork colour on or off. The player reads this itself, so a
  /// change is live without touching the rest of the app.
  Future<void> setArtworkColor(bool value) async {
    if (value == _artworkColor) return;
    _artworkColor = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_artKey, value);
  }

  /// Applies and stores the palette. The colours change before the write
  /// finishes; listeners rebuild the app.
  Future<void> setMode(AppPalette value) async {
    if (value == _mode) return;
    _mode = value;
    AppColors.mode = value;
    applySystemUiOverlay();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value.name);
  }
}
