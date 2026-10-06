import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Single cached artwork path. Memory + disk cache, bounded decode size,
/// no re-fetch on every 1/sec position tick. Gapless so song changes
/// don't flash. Square by default ([size]); pass [width]+[height] for
/// fixed-ratio boxes (rails, headers).
///
/// When [filePath] points at a downloaded high-resolution cover (the same
/// file the media notification uses), it is preferred over the network
/// [url] so large renderings — notably the full-screen player — stay sharp.
class Artwork extends StatelessWidget {
  final String url;
  final String? filePath;
  final double? size;
  final double? width;
  final double radius;
  final double? height;
  final BoxFit fit;
  final bool fillWidth;

  const Artwork(
    this.url, {
    super.key,
    this.filePath,
    this.size,
    this.width,
    this.radius = 12,
    this.height,
    this.fit = BoxFit.cover,
    this.fillWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final computedSize = size ?? (mq.size.width * 0.4).clamp(100, 300);
    final w = width ?? computedSize;
    final h = height ?? (width ?? computedSize);
    final px = ((width ?? computedSize) * mq.devicePixelRatio).round();
    // Prefer a downloaded high-res cover (the notification's file) when
    // present; it is validated at 480px+ so large renderings stay sharp.
    final local = filePath;
    if (local != null && local.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: fillWidth ? double.infinity : w,
          height: h,
          color: AppColors.mist,
          child: Image.file(
            File(local),
            width: fillWidth ? null : w,
            height: fillWidth ? null : h,
            fit: fit,
            cacheWidth: px.clamp(96, 1024),
            errorBuilder: (_, __, ___) => _fallback(w, h),
          ),
        ),
      );
    }
    if (url.isEmpty) return _fallback(w, h);
    // Single decode per art over the mist fill. A prior double stack fetched
    // and decoded the same URL twice per large card.
    if (!fillWidth && w >= 70) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: w,
          height: h,
          color: AppColors.mist,
          child: _networkImage(url, px, w, h,
              placeholder: () => const SizedBox.shrink(), fallbackWidth: w),
        ),
      );
    }
    final imgW = fillWidth ? null : w;
    final imgH = fillWidth ? null : h;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: fillWidth ? double.infinity : w,
        height: h,
        child: _networkImage(url, px, imgW, imgH,
            placeholder: () => Container(
                  width: imgW,
                  height: h,
                  color: AppColors.mist,
                ),
            fallbackWidth: imgW ?? computedSize),
      ),
    );
  }

  Widget _networkImage(
    String url,
    int px,
    double? w,
    double? h, {
    required Widget Function() placeholder,
    required double fallbackWidth,
  }) {
    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: '$url-$px',
      width: w,
      height: h,
      fit: fit,
      memCacheWidth: px.clamp(96, 1024),
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: const Duration(milliseconds: 120),
      useOldImageOnUrlChange: true,
      placeholder: (_, __) => placeholder(),
      errorWidget: (_, __, ___) => _fallback(fallbackWidth, h ?? fallbackWidth),
    );
  }

  Widget _fallback(double w, double h) => Container(
        width: w,
        height: h,
        color: AppColors.mist,
        child: const Icon(Icons.music_note, color: AppColors.mute),
      );
}

/// Artwork size the mini player renders at. The mini → full player hero
/// flight paints this same decode under the big cover, so both the thumb and
/// [CoverFlightShuttle] read it from here: change one and the flight re-decodes
/// from scratch, flashing blank where the thumb should be.
const double kMiniArtworkSize = 42;

/// Logical size of the full player cover on this device. Shared by
/// PlayerScreen and the hero flight landing on it so both decode one bitmap.
double coverLogicalSize(BuildContext context) =>
    (MediaQuery.sizeOf(context).width - 104).clamp(160.0, 320.0);

/// Full-bleed cover for a Hero flight between the mini player and the full
/// player. It fills whatever rect the flight animates, so the thumb can morph
/// into the large cover without [Artwork]'s fixed-size layout clipping or
/// overflowing.
///
/// Two stacked decodes keep the morph free of pops. Underneath sits the mini
/// player's thumb — same provider the thumb on screen uses, so it is a cache
/// hit and the first flight frame is already the artwork instead of a blank
/// card. The player's larger decode fades in over it once ready. The corner
/// radius rides the flight too, instead of snapping 10 → 20 on landing.
class CoverFlightShuttle extends StatelessWidget {
  final String url;
  final String? filePath;
  final Animation<double> animation;

  /// Radius at the thumb end and the full player end of the flight.
  final double beginRadius;
  final double endRadius;

  const CoverFlightShuttle(
    this.url, {
    super.key,
    this.filePath,
    required this.animation,
    this.beginRadius = 10,
    this.endRadius = 20,
  });

  /// The player's cover decode, transparent until it is ready so the thumb
  /// underneath keeps showing in the meantime.
  Widget? _cover(BuildContext context) {
    final px = (coverLogicalSize(context) *
            MediaQuery.devicePixelRatioOf(context))
        .round();
    final local = filePath;
    if (local != null && local.isNotEmpty) {
      return Image.file(
        File(local),
        fit: BoxFit.cover,
        cacheWidth: px.clamp(96, 1024),
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    if (url.isEmpty) return null;
    // Same cacheKey/decode as the player's [Artwork] so the flight shares its
    // loaded bitmap instead of fetching a second copy.
    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: '$url-$px',
      fit: BoxFit.cover,
      memCacheWidth: px.clamp(96, 1024),
      fadeInDuration: const Duration(milliseconds: 140),
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => const SizedBox.shrink(),
      errorWidget: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cover = _cover(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => ClipRRect(
        borderRadius: BorderRadius.circular(
            beginRadius + (endRadius - beginRadius) * animation.value),
        child: child,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Artwork(url, size: kMiniArtworkSize, radius: 0),
          if (cover != null) cover,
        ],
      ),
    );
  }
}
