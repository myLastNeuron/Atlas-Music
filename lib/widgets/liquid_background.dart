import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Deep-neutral backdrop with soft gray washes. The washes stay visible
/// through frosted surfaces, so the whole UI reads as layered glass.
/// RepaintBoundary wraps each wash so content repaints never repaint
/// the background — cheap on low-end hardware.
///
/// The washes drift slowly (one controller, transform-only, no repaint).
/// Motion is skipped entirely when the OS "reduce motion" flag is set.
class LiquidBackground extends StatefulWidget {
  final Widget child;
  const LiquidBackground({super.key, required this.child});

  @override
  State<LiquidBackground> createState() => _LiquidBackgroundState();
}

class _LiquidBackgroundState extends State<LiquidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: AppMotion.ambient,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // React to the setting changing at runtime as well as at first build.
    if (AppMotion.reduced(context)) {
      if (_drift.isAnimating) _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  /// Drift one blob with a transform only. [blob] is prebuilt and lives
  /// inside its own RepaintBoundary, so per-frame work is one transform
  /// update with NO relayout and NO rebuild of the blob/Stack.
  Widget _driftBlob(Widget blob,
      {required double phase, required double amount, required bool reduced}) {
    return AnimatedBuilder(
      animation: _drift,
      child: RepaintBoundary(child: blob),
      builder: (context, child) {
        if (reduced) return child!;
        final angle = (_drift.value + phase) * 2 * math.pi;
        return Transform.translate(
          offset:
              Offset(math.sin(angle) * amount, math.cos(angle) * amount * 0.7),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return Container(
      color: AppColors.paper,
      child: Stack(
        children: [
          Positioned(
            top: -120,
            left: -100,
            child: _driftBlob(
              const _Blob(size: 340, color: Color(0xFF3A3A46), opacity: 0.55),
              phase: 0.0,
              amount: 26,
              reduced: reduced,
            ),
          ),
          Positioned(
            top: -80,
            right: -110,
            child: _driftBlob(
              const _Blob(size: 320, color: Color(0xFF2A2A33), opacity: 0.7),
              phase: 0.33,
              amount: 20,
              reduced: reduced,
            ),
          ),
          Positioned(
            bottom: -140,
            left: -40,
            right: -40,
            child: _driftBlob(
              const _FloorBlob(color: Color(0xFF23232B), opacity: 0.8),
              phase: 0.66,
              amount: 16,
              reduced: reduced,
            ),
          ),
          Positioned(
            bottom: 60,
            right: -80,
            child: _driftBlob(
              const _Blob(size: 260, color: Color(0xFF33333D), opacity: 0.5),
              phase: 0.85,
              amount: 30,
              reduced: reduced,
            ),
          ),
          Positioned.fill(child: widget.child),
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final double size;
  final Color color;
  final double opacity;
  const _Blob({required this.size, required this.color, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: _blobDecoration(color, opacity),
    );
  }
}

class _FloorBlob extends StatelessWidget {
  final Color color;
  final double opacity;
  const _FloorBlob({required this.color, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 340,
      decoration: _blobDecoration(color, opacity),
    );
  }
}

BoxDecoration _blobDecoration(Color color, double opacity) => BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [
          color.withValues(alpha: opacity),
          color.withValues(alpha: 0.0),
        ],
      ),
    );

/// Transparent glass surface: a see-through base under a light-catching
/// sheen, a soft rim and a drop shadow. No backdrop blur. [strength] sets how
/// much sheen the surface holds (same scale as [GlassPanel.opacity]).
BoxDecoration liquidGlassDecoration(double radius, {double strength = 0.08}) =>
    BoxDecoration(
      color: AppColors.glass,
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.05 + strength * 0.3),
          Colors.white.withValues(alpha: 0.015),
          Colors.transparent,
        ],
        stops: const [0, 0.5, 1],
      ),
      border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 24,
          offset: const Offset(0, 12),
        ),
      ],
    );

/// Liquid-glass panel: transparent, no backdrop blur. The look comes from the
/// gradient and rim in [liquidGlassDecoration].
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double opacity;

  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding,
    this.opacity = 0.08,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          padding: padding,
          decoration: liquidGlassDecoration(radius, strength: opacity),
          child: child,
        ),
      ),
    );
  }
}
