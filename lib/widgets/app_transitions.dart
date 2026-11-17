import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Pull-to-refresh on local data resolves within a frame, so the indicator
/// never spins and the pull reads as a no-op. Keep it up long enough to see;
/// a slower reload still runs to completion because the hold overlaps it.
Future<void> minRefresh(Future<void> Function() reload) async {
  final hold = Future<void>.delayed(const Duration(milliseconds: 700));
  await reload();
  await hold;
}

/// Shared page route: fade + slide + scale for normal pushes. The full player
/// (`slideUp: true`) is a card that grows out of the mini bar instead (see
/// [buildPlayerPageCard]); its cover [Hero] flies thumb→big on the same curve
/// and over the same window, so the artwork morphs rather than appearing
/// already large. The player route is transparent so the route below keeps
/// painting under the growing card. Back gesture stays interactive, input is
/// never blocked.
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required Widget Function(BuildContext) builder,
    super.settings,
    bool slideUp = false,
  }) : super(
          // The player's card grows over the route below, so the route below
          // must stay painted while it does.
          opaque: !slideUp,
          transitionDuration: slideUp ? AppMotion.playerOpen : AppMotion.page,
          reverseTransitionDuration:
              slideUp ? AppMotion.playerClose : AppMotion.page,
          pageBuilder: (context, _, __) => HeroMode(
            // Reduce motion snaps the page into place; flying the cover
            // across a screen that doesn't move would read as the artwork
            // alone gliding over a frozen app.
            enabled: !(slideUp && AppMotion.reduced(context)),
            child: builder(context),
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              slideUp
                  ? buildPlayerPageCard(context, animation, child)
                  : buildAppTransition(
                      context, animation, secondaryAnimation, child),
        );
}

/// The rect tween for a player cover flight. The Hero's own curve is linear
/// (the player's curve is applied here instead), so the cover leaves and
/// lands on the same motion as the card that grows around it. Keeps the
/// Material arc: the cover swings up, it does not slide in a straight line.
class PlayerFlightRectTween extends MaterialRectArcTween {
  PlayerFlightRectTween({
    required super.begin,
    required super.end,
    required this.curve,
  });

  final Curve curve;

  @override
  Rect? transform(double t) => super.transform(curve.transform(t));
}

/// The part of the player flight where the card's paper is fully opaque over
/// whatever sits under it. Below this the paper fades away and the mini bar is
/// visible again, so the bar's frost flips while it is still covered.
const double kPlayerCardOpaqueFrom = 0.30;

/// The player's motion: the mini bar's card grows into the full player. The
/// card's rect is interpolated from the bar's rectangle to the window in both
/// directions, so the top edge sweeps up from the bar's top and the bottom
/// edge down from the bar's bottom while the corners unfurl from the bar's
/// 22 px to square: one continuous geometry, open and close.
///
/// Runs for the same [AppMotion.playerOpen]/[playerClose] window and the same
/// curves as the cover [Hero], and hero rects are measured against the route
/// subtree, so cover and card always move as one. Only compositor work happens
/// per frame: the card is one [Positioned] leaf, the radius a [ClipRRect] paint
/// and the paper one rect fill. The page is hoisted into the
/// [AnimatedBuilder]'s child and hosted at the window's fixed size inside an
/// [OverflowBox], so it is built once and never resized; it is clipped to the
/// card, so what the flight composites is card-sized and not window-sized. The
/// route below stays put (see [playerRouteAbove]), so the bar the card grows
/// out of never dissolves. Respects reduce-motion.
Widget buildPlayerPageCard(
  BuildContext context,
  Animation<double> animation,
  Widget child,
) {
  if (AppMotion.reduced(context)) return child;
  // The route controller runs backwards on close; the two curves are mirrors,
  // so the card leaves the full player fast and settles into the bar.
  final bool closing = animation.status == AnimationStatus.reverse;
  final Curve curve =
      closing ? AppMotion.playerCloseCurve : AppMotion.playerOpenCurve;
  // drive() instead of a CurvedAnimation: the latter registers a status
  // listener on the route controller and is never disposed when built here.
  final curved = animation.drive(CurveTween(curve: curve));
  final Size window = MediaQuery.sizeOf(context);
  // A bar was tapped: its rectangle is where the card starts and ends. Opened
  // from a song row there is no bar rect, so use where the floating bar sits.
  final Rect bar = playerCardFrom ??
      Rect.fromLTRB(
          16, window.height - 92, window.width - 16, window.height - 22);
  final Rect screen = Offset.zero & window;
  return AnimatedBuilder(
    animation: curved,
    // Hoisted: the page (cover, glass, transport) is built once and never per
    // frame; the builder below only rebuilds the card geometry and fades.
    child: child,
    builder: (context, page) {
      final Rect card = Rect.lerp(bar, screen, curved.value)!;
      // Linear route value: the surfaces fade on raw progress, so their ramps
      // are not compressed into the start of an ease-out.
      final double v = animation.value;
      // Page first, paper over it. The paper hides the app (and the bar's
      // glass) while the card is small; it hands over to the page as soon as
      // the card is big enough to show the page, and is gone well before the
      // flight ends so the last frames are a settled player, not a fade:
      //   v < 0.30     paper ramps in over the app.
      //   0.30 .. 0.42 opaque paper (the page starts painting at 0.36, under it).
      //   0.42 .. 0.80 paper fades over the opaque page -> page entirely
      //                visible by 0.8.
      //   v > 0.80     paper = 0, the page alone.
      // The page is opaque (its own LiquidBackground), which is what lets the
      // paper be a plain colour with alpha instead of an [Opacity] layer.
      final double paper = v < 0.42
          ? (v / kPlayerCardOpaqueFrom).clamp(0.0, 1.0)
          : 1 - ((v - 0.42) / 0.38).clamp(0.0, 1.0);
      return Stack(
        children: [
          Positioned(
            left: card.left,
            top: card.top,
            width: card.width,
            height: card.height,
            child: ClipRRect(
              // Test anchor for the card's own rect (the page inside it is
              // window-sized and clipped, the card is what must land on the
              // bar).
              key: const ValueKey('player_sheet'),
              // Square corners at rest cost no clip layer; the card is the
              // whole window by then.
              clipBehavior: curved.value >= 1 ? Clip.none : Clip.antiAlias,
              // Corners unfurl from the bar's radius to square.
              borderRadius: BorderRadius.circular(22 * (1 - curved.value)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Cull the page to the card. The rounded clip above is
                  // tighter, so this changes nothing on screen; it keeps the
                  // flight's layers and the page's raster card-sized instead of
                  // window-sized. Empty until the page's fade starts (the paper
                  // is opaque until then), so the page costs no raster before.
                  // The paper starts fading at 0.42; from 0.36 the page paints
                  // under it so the cross-fade never shows the app behind.
                  // shortcut: the page's own picture stays window-sized because
                  // the page never resizes, so the clip culls per draw op; lay
                  // the page out card-sized if that traversal ever shows up.
                  ClipRect(
                    clipper: _CardClip(v >= 0.36),
                    // The page keeps the window's size (nothing inside it
                    // resizes) and is anchored to the card's bottom edge, so
                    // the growing top edge sweeps up and reveals it from the
                    // bottom.
                    child: OverflowBox(
                      alignment: Alignment.bottomCenter,
                      minWidth: window.width,
                      maxWidth: window.width,
                      minHeight: window.height,
                      maxHeight: window.height,
                      // Own layer: the card rebuilds above it, the page paints
                      // once.
                      child: RepaintBoundary(child: page!),
                    ),
                  ),
                  // The card's own surface, so the glass bar under it never
                  // hard-swaps to paper: opaque over the first third, then it
                  // hands over to the page. Ignored by pointers because it
                  // sits over the page now; the route's barrier already keeps
                  // unhandled taps from reaching the route below.
                  IgnorePointer(
                    child: ColoredBox(
                      color: AppColors.paper.withValues(alpha: paper),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Clips the window-sized page to the card exactly: the clip is the card's own
/// rect, and an empty rect until [visible] so a page nobody can see yet costs
/// no raster. The clip lives in the card's box (the [OverflowBox] inside it does
/// the bottom-center offset), so no page-space arithmetic is needed.
class _CardClip extends CustomClipper<Rect> {
  const _CardClip(this.visible);

  final bool visible;

  @override
  Rect getClip(Size size) => visible ? Offset.zero & size : Rect.zero;

  @override
  bool shouldReclip(_CardClip oldClipper) => oldClipper.visible != visible;
}

/// Push with the shared transition. Drop-in for MaterialPageRoute.
Future<T?> pushAppPage<T>(BuildContext context, Widget page,
    {String? routeName, bool slideUp = false}) {
  return Navigator.push<T>(
    context,
    AppPageRoute<T>(
      builder: (_) => page,
      settings: routeName == null ? null : RouteSettings(name: routeName),
      slideUp: slideUp,
    ),
  );
}

/// Lightweight touch response for cards and controls: the surface compresses
/// slightly while pressed and nudges away from the touch point, then glides
/// back with a short spring-like ease. Pointer listening leaves the child's
/// tap/scroll gesture recognizers untouched.
class MotionPress extends StatefulWidget {
  final Widget child;
  final double scale;
  const MotionPress({super.key, required this.child, this.scale = 0.975});

  @override
  State<MotionPress> createState() => _MotionPressState();
}

class _MotionPressState extends State<MotionPress> {
  bool _pressed = false;
  Offset _repelOffset = Offset.zero;

  void _onPointerDown(PointerDownEvent event) {
    final renderObject = context.findRenderObject();
    var offset = Offset.zero;
    if (renderObject is RenderBox && renderObject.hasSize) {
      final away = renderObject.size.center(Offset.zero) - event.localPosition;
      final distance = away.distance;
      if (distance > 0) offset = away / distance * 3.5;
    }
    setState(() {
      _pressed = true;
      _repelOffset = offset;
    });
  }

  void _releasePointer(PointerEvent _) {
    if (!_pressed && _repelOffset == Offset.zero) return;
    setState(() {
      _pressed = false;
      _repelOffset = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    final micro = AppMotion.dur(context, AppMotion.micro);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerUp: _releasePointer,
      onPointerCancel: _releasePointer,
      child: TweenAnimationBuilder<Offset>(
        tween: Tween<Offset>(begin: Offset.zero, end: _repelOffset),
        duration: micro,
        curve: Curves.easeOutBack,
        builder: (context, offset, child) => Transform.translate(
          offset: offset,
          child: AnimatedScale(
            scale: _pressed ? widget.scale : 1,
            duration: micro,
            curve: Curves.easeOutCubic,
            child: child,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

/// One-shot fade + rise for freshly mounted content (headers, cards).
/// TweenAnimationBuilder owns its controller internally: no manual vsync,
/// no dispose bugs, no restart on parent rebuilds.
class FadeSlideIn extends StatelessWidget {
  final Widget child;
  final Duration delay;
  const FadeSlideIn(
      {super.key, required this.child, this.delay = Duration.zero});

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: AppMotion.entrance + delay,
      curve: AppMotion.curve,
      builder: (context, value, child) {
        final v = ((value * (AppMotion.entrance + delay).inMilliseconds -
                    delay.inMilliseconds) /
                AppMotion.entrance.inMilliseconds)
            .clamp(0.0, 1.0);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - v)),
            child: child,
          ),
        );
      },
      // Retain the child's raster so the per-frame opacity/translate during the
      // entrance composites a cached layer instead of repainting the whole
      // (often heavy) subtree every frame.
      child: RepaintBoundary(child: child),
    );
  }
}

/// Staggered entrance for fixed, non-recycled groups (onboarding sections,
/// settings tiles, stat cards, transport rows). Each item fades + rises with
/// an incremental delay. Built on [FadeSlideIn] so it is ticker-driven (no
/// pending timers) and reduce-motion users get static content.
class Stagger extends StatelessWidget {
  final Widget child;
  final int index;
  const Stagger({super.key, required this.child, this.index = 0});

  @override
  Widget build(BuildContext context) {
    // Cap the cascade so deep lists do not wait seconds to appear.
    final i = index > 12 ? 12 : index;
    return FadeSlideIn(delay: AppMotion.stagger * i, child: child);
  }
}

/// Shared fade + tiny rise for [AnimatedSwitcher] section swaps (loading →
/// empty → content) so every screen's state change feels the same.
Widget fadeRiseTransition(Widget child, Animation<double> animation) {
  final curved = CurvedAnimation(parent: animation, curve: AppMotion.curve);
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.025),
        end: Offset.zero,
      ).animate(curved),
      // Retain the child's layer so the fade/slide animate a cached raster
      // instead of repainting the incoming screen every frame.
      child: RepaintBoundary(child: child),
    ),
  );
}

/// Animated play/pause swap: fade + scale, fixed size so layout never jumps.
class PlayPauseIcon extends StatelessWidget {
  final bool playing;
  final double size;
  final Color color;
  const PlayPauseIcon(
      {super.key,
      required this.playing,
      required this.size,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.dur(context, AppMotion.micro),
      switchInCurve: AppMotion.curve,
      switchOutCurve: AppMotion.curve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: Icon(
        playing ? Icons.pause : Icons.play_arrow,
        key: ValueKey(playing),
        size: size,
        color: color,
      ),
    );
  }
}
