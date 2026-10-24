import 'package:flutter/material.dart';
import '../services/glass_settings.dart';
import '../theme/app_theme.dart';

/// Flat deep-neutral backdrop. Frosted surfaces layer on top of it on their
/// own, so nothing is painted behind them: no glow washes, no drift, and no
/// animation keeping the background awake.
class LiquidBackground extends StatelessWidget {
  final Widget child;

  /// Optional tint painted under the content: the full player's artwork
  /// colour. Null keeps the plain page colour.
  final Gradient? gradient;

  const LiquidBackground({super.key, required this.child, this.gradient});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: gradient == null ? AppColors.paper : null,
          gradient: gradient,
        ),
        child: child,
      );
}

/// The surface opacity at the two ends of the setting: see-through at 0,
/// milky at 1. Even the transparent end keeps a third of the tint, so white
/// text stays readable over album art.
const double kGlassMinOpacity = 0.30;
const double kGlassMaxOpacity = 0.90;

/// The tint opacity for a level: 0 = transparent, 1 = translucent.
double glassOpacity(double level) =>
    kGlassMinOpacity +
    (kGlassMaxOpacity - kGlassMinOpacity) * level.clamp(0.0, 1.0);

/// Transparent glass surface: a flat see-through tint, a soft rim and a drop
/// shadow. [level] is the setting: 0 = transparent, 1 = translucent.
///
/// ponytail: no white sheen, no backdrop blur. The sheen was a white wash
/// blooming over every panel, and a blur re-renders the whole area behind each
/// surface on every frame — that is what made the app crawl. A flat tint costs
/// nothing and is what the slider actually controls.
BoxDecoration liquidGlassDecoration(
  BorderRadius borderRadius, {
  double level = 0.5,
  Border? border,
  bool shadow = true,
}) {
  final tint = AppColors.glass.withValues(alpha: glassOpacity(level));
  return BoxDecoration(
    borderRadius: borderRadius,
    color: tint,
    border: border ?? Border.all(color: AppColors.glassBorder),
    boxShadow: shadow
        ? [
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ]
        : null,
  );
}

/// The one glass surface: every panel, bar, sheet and menu is drawn with
/// this, so the setting reaches all of them.
///
/// The surface reads the level itself, so changing the setting rebuilds this
/// widget only — never the app. [strength] is the sheen, [shadow] the deep
/// drop shadow of the floating panels, [border] a custom rim.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool shadow;
  final Border? border;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.padding,
    this.shadow = true,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        decoration: liquidGlassDecoration(
          borderRadius,
          level: glassLevel(context),
          border: border,
          shadow: shadow,
        ),
        // Transparent Material with the surface's own shape. Ink (press
        // highlight + ripple) is painted by the nearest Material and clipped
        // to its shape, so a held row lights up as a rounded rect that
        // follows the surface instead of a sharp rectangle.
        child: Material(
          type: MaterialType.transparency,
          shape: RoundedRectangleBorder(borderRadius: borderRadius),
          clipBehavior: Clip.antiAlias,
          child: padding == null
              ? child
              : Padding(padding: padding!, child: child),
        ),
      ),
    );
  }
}

/// Liquid-glass panel: the standard glass surface with the app's
/// transparency level applied.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;

  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(radius),
      padding: padding,
      child: child,
    );
  }
}
