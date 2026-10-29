import 'dart:ui' show ImageFilter;

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

/// Frost strength of every glass surface. One fixed value: the transparency
/// setting moves the tint, so the filter stays the same small pass everywhere.
/// Above ~16 the blur starts to cost real frames on a mid-range phone.
/// Frost strength of a glass surface. Small on purpose: the tint does most of
/// the work, and every point of sigma is paid on every frame the surface sits
/// over something that moves (a scrolling list, a playing video).
const double kGlassBlurSigma = 10;

/// Transparent glass surface: a soft rim, a drop shadow, and — for the
/// surfaces that float over moving content — a real frost. [level] is the
/// setting: 0 = transparent, 1 = translucent.
///
/// ponytail: the tint stays flat (no white sheen — it bloomed over every
/// panel).
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
/// widget only — never the app. [shadow] is the deep drop shadow of the
/// floating panels, [border] a custom rim, [width] a fixed or infinite width
/// for a panel that must fill its slot.
///
/// [blur] is off by default: a panel inside the page has only the flat backdrop
/// behind it, so a filter there costs a full repaint per frame and shows
/// nothing. The floating chrome — nav bar, mini player, sheets, menus — opts in,
/// because that is where album art and lists actually scroll underneath.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool shadow;
  final Border? border;
  final double? width;
  final bool blur;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.padding,
    this.shadow = true,
    this.border,
    this.width,
    this.blur = false,
  });

  @override
  Widget build(BuildContext context) {
    final panel = Container(
      width: width,
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
        child:
            padding == null ? child : Padding(padding: padding!, child: child),
      ),
    );
    return ClipRRect(
      borderRadius: borderRadius,
      child: blur
          ? BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: kGlassBlurSigma,
                sigmaY: kGlassBlurSigma,
              ),
              child: panel,
            )
          : panel,
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
