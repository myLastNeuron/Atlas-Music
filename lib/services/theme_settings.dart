import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';

/// Appearance: light or dark, and whether the full player takes its colour
/// from the artwork. The mode swaps [AppColors] and the app rebuilds from the
/// root, which is the only way the palette can reach widgets that read the
/// colours themselves; the artwork colour is read by the player alone.
class ThemeSettings extends ChangeNotifier {
  static const _key = 'theme_light';
  static const _artKey = 'player_artwork_color';

  bool _light = false;
  bool _artworkColor = false;

  bool get isLight => _light;

  /// The full player tints itself with the current artwork's dominant colour
  /// instead of the app palette. Off by default; nothing else is affected.
  bool get artworkColor => _artworkColor;

  /// Reads the stored mode before the first frame, so the app never starts in
  /// the wrong palette and then flips.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _light = prefs.getBool(_key) ?? false;
    _artworkColor = prefs.getBool(_artKey) ?? false;
    AppColors.setLight(_light);
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

  /// Applies and stores the mode. The palette changes before the write
  /// finishes; listeners rebuild the app.
  Future<void> setLight(bool value) async {
    if (value == _light) return;
    _light = value;
    AppColors.setLight(value);
    applySystemUiOverlay();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}
