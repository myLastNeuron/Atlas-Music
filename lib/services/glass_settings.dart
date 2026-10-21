import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How much of the background shows through the app's glass surfaces:
/// 0 = transparent (see-through), 1 = translucent (milky).
///
/// This is a plain opacity change, so it costs nothing to draw — no backdrop
/// filters, no per-frame blur passes. Persisted, and applied live: the
/// surfaces read it themselves, so changing it rebuilds only the surfaces.
class GlassSettings extends ChangeNotifier {
  static const _key = 'glass_translucency';

  /// A fresh install lands on the app's original glass look.
  static const double defaultLevel = 0.5;

  double _level = defaultLevel;

  /// 0 = transparent, 1 = translucent.
  double get level => _level;

  /// Reads the stored level. A fresh install keeps [defaultLevel].
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_key);
    if (stored == null) return;
    final value = stored.clamp(0.0, 1.0);
    if (value == _level) return;
    _level = value;
    notifyListeners();
  }

  /// Sets the level and stores it. The change is live before the write
  /// finishes, so dragging the slider never waits on disk.
  Future<void> setLevel(double value) async {
    final v = value.clamp(0.0, 1.0);
    if (v == _level) return;
    _level = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, v);
  }
}

/// Makes the level available to the surfaces below it and rebuilds only
/// those when it changes.
class GlassScope extends InheritedNotifier<GlassSettings> {
  const GlassScope({
    super.key,
    required GlassSettings super.notifier,
    required super.child,
  });
}

/// The glass settings in scope, or null when there is none (a widget used
/// outside the app, a test, a preview).
GlassSettings? glassSettings(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<GlassScope>()?.notifier;

/// The level the surfaces around [context] are drawn with.
double glassLevel(BuildContext context) =>
    glassSettings(context)?.level ?? GlassSettings.defaultLevel;
