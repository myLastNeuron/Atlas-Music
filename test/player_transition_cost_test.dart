import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/theme/app_theme.dart';
import 'package:atlas_music/widgets/app_transitions.dart';

// Regression: the card's flight must not composite window-sized offscreen
// layers. The page is window-sized (it never resizes), but it is clipped to the
// card, so every layer the flight creates per frame is bounded by the card —
// and there is no alpha (saveLayer) layer at all: the paper fades as a plain
// rect fill over the opaque page.
//
// The old builder wrapped the page in an Opacity whose alpha changed every
// frame, which made the engine build a window-sized offscreen buffer and blend
// it back over the window on each frame of the flight. Both assertions below
// fail on that code: it had an OpacityLayer and no hard clip on the page.
void main() {
  testWidgets('the flight composites card-sized layers, not window-sized ones',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const bar = Rect.fromLTRB(16, 700, 384, 770);
    playerCardFrom = bar;
    addTearDown(() => playerCardFrom = null);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => pushAppPage(
                ctx,
                const Scaffold(body: SizedBox.expand(key: ValueKey('page'))),
                routeName: '/player',
                slideUp: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    final card = find.byKey(const ValueKey('player_sheet'));
    final pageBoundary =
        find.descendant(of: card, matching: find.byType(RepaintBoundary)).first;

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();

    const window = Rect.fromLTWH(0, 0, 400, 800);
    final clipped = <Rect>[];

    // Sample only while the flight is running: once it lands the card is the
    // window with no clip layer of its own, which is not what this guards.
    for (var elapsed = 15;
        elapsed < AppMotion.playerOpen.inMilliseconds;
        elapsed += 15) {
      await tester.pump(const Duration(milliseconds: 15));

      final cardRect = tester.getRect(card);
      final sheetLayer = tester.renderObject<RenderObject>(card).debugLayer!;
      final layers = <Layer>[sheetLayer, ..._subtree(sheetLayer)];

      // No texture-alpha layer anywhere under the card: an OpacityLayer is a
      // per-frame offscreen pass, which is what made the flight lag.
      expect(layers.whereType<OpacityLayer>(), isEmpty,
          reason: 'the card must fade by colour, not by compositing alpha');

      // The page is still recorded at the window's size ...
      final pageLayer =
          tester.renderObject<RenderObject>(pageBoundary).debugLayer!;
      final pagePictures = _subtree(pageLayer).whereType<PictureLayer>();
      expect(pagePictures, isNotEmpty);
      expect(
          pagePictures.map((p) => p.canvasBounds.size), contains(window.size),
          reason: 'the page must stay window-sized, not be shrunk to the card');

      // ... and every raster the card itself records is clipped to the card.
      for (final picture in layers.whereType<PictureLayer>()) {
        if (_under(picture, pageLayer)) continue;
        _expectInside(cardRect, picture.canvasBounds);
      }

      // The page's window-sized raster sits under a clip that is the card's
      // rect (empty until the page's fade starts), so the flight rasterises
      // the card and nothing outside it.
      final clip = _firstClipAbove(pageLayer);
      expect(clip, isNotNull, reason: 'the page must be culled to the card');
      final clipRect = clip!.clipRect!;
      if (clipRect.isEmpty) continue;
      _expectRect(clipRect, cardRect);
      clipped.add(cardRect);
    }

    // At least one sampled frame culled the page to a card that was smaller
    // than the window: the bound is the card, not the window.
    expect(
      clipped
          .any((r) => r.width < window.width - 1 && r.height < window.height),
      isTrue,
      reason: 'the cull must be tighter than the window mid-flight',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
  });
}

/// Every layer below [root].
Iterable<Layer> _subtree(Layer root) sync* {
  if (root is! ContainerLayer) return;
  for (Layer? child = root.firstChild;
      child != null;
      child = child.nextSibling) {
    yield child;
    yield* _subtree(child);
  }
}

/// Whether [layer] sits inside [ancestor]'s subtree.
bool _under(Layer layer, Layer ancestor) {
  for (Layer? l = layer.parent; l != null; l = l.parent) {
    if (identical(l, ancestor)) return true;
  }
  return false;
}

/// The nearest hard clip above [layer]: the page's cull.
ClipRectLayer? _firstClipAbove(Layer layer) {
  for (Layer? l = layer.parent; l != null; l = l.parent) {
    if (l is ClipRectLayer) return l;
  }
  return null;
}

void _expectRect(Rect actual, Rect expected, {double eps = 0.01}) {
  expect(actual.left, closeTo(expected.left, eps));
  expect(actual.top, closeTo(expected.top, eps));
  expect(actual.right, closeTo(expected.right, eps));
  expect(actual.bottom, closeTo(expected.bottom, eps));
}

void _expectInside(Rect outer, Rect inner, {double eps = 0.01}) {
  expect(inner.left, greaterThanOrEqualTo(outer.left - eps));
  expect(inner.top, greaterThanOrEqualTo(outer.top - eps));
  expect(inner.right, lessThanOrEqualTo(outer.right + eps));
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom + eps));
}
