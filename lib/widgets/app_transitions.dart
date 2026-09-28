import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Consistent 240ms fade + slide + scale route used for the player and
/// playlist pages. Framework-driven (no controllers to leak), back gesture
/// stays interactive, input is never blocked.
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required Widget Function(BuildContext) builder,
    super.settings,
  }) : super(
          transitionDuration: AppMotion.page,
          reverseTransitionDuration: AppMotion.page,
          pageBuilder: (context, _, __) => builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppMotion.curve,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05),
                  end: Offset.zero,
                ).animate(curved),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
                  child: child,
                ),
              ),
            );
          },
        );
}

/// Push with the shared transition. Drop-in for MaterialPageRoute.
Future<T?> pushAppPage<T>(BuildContext context, Widget page,
    {String? routeName}) {
  return Navigator.push<T>(
    context,
    AppPageRoute<T>(
      builder: (_) => page,
      settings: routeName == null ? null : RouteSettings(name: routeName),
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
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerUp: _releasePointer,
      onPointerCancel: _releasePointer,
      child: TweenAnimationBuilder<Offset>(
        tween: Tween<Offset>(begin: Offset.zero, end: _repelOffset),
        duration: AppMotion.micro,
        curve: Curves.easeOutBack,
        builder: (context, offset, child) => Transform.translate(
          offset: offset,
          child: AnimatedScale(
            scale: _pressed ? widget.scale : 1,
            duration: AppMotion.micro,
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
      child: child,
    );
  }
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
      duration: AppMotion.micro,
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
