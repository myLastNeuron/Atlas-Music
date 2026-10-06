import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Shared page route: fade + slide + scale for normal pushes, and for the
/// full player (`slideUp: true`) a quick fade whose cover [Hero] flies from
/// the mini player. Framework-driven (no controllers to leak), back gesture
/// stays interactive, input is never blocked.
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required Widget Function(BuildContext) builder,
    super.settings,
    bool slideUp = false,
  }) : super(
          transitionDuration:
              slideUp ? AppMotion.playerOpen : AppMotion.page,
          reverseTransitionDuration:
              slideUp ? AppMotion.playerClose : AppMotion.page,
          pageBuilder: (context, _, __) => builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              slideUp
                  ? buildPlayerTransition(
                      context, animation, secondaryAnimation, child)
                  : buildAppTransition(
                      context, animation, secondaryAnimation, child),
        );
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
