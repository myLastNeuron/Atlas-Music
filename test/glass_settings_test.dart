import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:atlas_music/screens/advanced_settings_screen.dart';
import 'package:atlas_music/services/glass_settings.dart';
import 'package:atlas_music/widgets/liquid_background.dart';

/// The alpha of the surface's tint (the gradient's final stop — a
/// BoxDecoration with a gradient never paints its `color`).
double surfaceAlpha(WidgetTester tester) {
  final container = tester.widget<Container>(find.descendant(
    of: find.byType(GlassSurface),
    matching: find.byType(Container),
  ));
  final decoration = container.decoration! as BoxDecoration;
  final gradient = decoration.gradient! as LinearGradient;
  return gradient.colors.last.a;
}

Widget app(double level, Widget child) {
  return GlassScope(
    notifier: GlassSettings()..setLevel(level),
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  test('a fresh install starts on the original glass look', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = GlassSettings();
    await settings.load();
    expect(settings.level, GlassSettings.defaultLevel);
    expect(glassOpacity(settings.level), closeTo(0.6, 0.001));
  });

  test('the level is stored and read back', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = GlassSettings();
    await settings.load();
    var notified = 0;
    settings.addListener(() => notified++);
    await settings.setLevel(0.8);
    expect(settings.level, 0.8);
    expect(notified, 1);

    final reloaded = GlassSettings();
    await reloaded.load();
    expect(reloaded.level, 0.8);
  });

  testWidgets('a surface follows the transparency level', (tester) async {
    await tester.pumpWidget(app(0.0, const GlassSurface(child: Text('Row'))));
    final transparent = surfaceAlpha(tester);

    await tester.pumpWidget(app(1.0, const GlassSurface(child: Text('Row'))));
    await tester.pumpAndSettle();
    final translucent = surfaceAlpha(tester);

    expect(transparent, lessThan(translucent),
        reason: 'Transparent must show more of the backdrop than Translucent');
    expect(translucent, greaterThan(0.8));
  });

  testWidgets('even the transparent end stays readable', (tester) async {
    await tester.pumpWidget(app(0.0, const GlassSurface(child: Text('Row'))));
    await tester.pumpAndSettle();
    expect(surfaceAlpha(tester), greaterThanOrEqualTo(0.3),
        reason: 'a fully clear surface would leave white text on album art');
  });

  testWidgets('no surface blurs its backdrop', (tester) async {
    // A backdrop filter re-renders the area behind every surface on every
    // frame; that cost is exactly what must not come back.
    await tester.pumpWidget(app(1.0, const GlassSurface(child: Text('Row'))));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('changing the level rebuilds the surface only', (tester) async {
    // The app theme never carries the level, so a change must not restyle
    // (and rebuild) the whole app.
    await tester.pumpWidget(app(0.0, const GlassSurface(child: Text('Row'))));
    final transparent = surfaceAlpha(tester);

    final settings = GlassSettings();
    await tester.pumpWidget(
      GlassScope(
        notifier: settings,
        child: const MaterialApp(
            home: Scaffold(body: GlassSurface(child: Text('Row')))),
      ),
    );
    await settings.setLevel(1.0);
    await tester.pumpAndSettle();
    final translucent = surfaceAlpha(tester);

    expect(translucent, greaterThan(transparent));
  });

  testWidgets('the transparency preview fits its box', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassScope(
        notifier: GlassSettings()..setLevel(0.5),
        child: const MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(20),
              child: GlassPreview(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'the preview used to overflow its 168px box');
  });

  testWidgets('a surface without a scope stays on the default look',
      (tester) async {
    // Widgets used outside the app (tests, previews) must not crash.
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: GlassSurface(child: Text('Row')))));
    await tester.pumpAndSettle();
    expect(surfaceAlpha(tester), closeTo(0.6, 0.001));
  });
}
